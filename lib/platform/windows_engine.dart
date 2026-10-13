import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';
import '../core/network_context.dart';
import '../core/profile_policy.dart';
import '../core/traffic.dart';
import 'desktop_capabilities.dart';
import 'vpn_engine.dart';
import 'windows_config.dart';
import 'windows_probe.dart';

class WindowsEngine implements VpnEngine, TrafficSource, DesktopCapabilities {
  final _events = StreamController<EngineEvent>.broadcast();
  final _probe = WindowsProbe();
  final _root = File(Platform.resolvedExecutable).parent.path;
  Process? _xray;
  bool _active = false, _stopping = false;
  int _epoch = 0, _logBytes = 0;
  String _protocol = '', _detail = 'Windows VPN не запускался';
  String? _privateDir;
  String get _alias => _protocol == 'wireguard' ? 'QuietVPN-AWG' : WindowsConfig.adapter;
  String _file(String name) => '$_root${Platform.pathSeparator}engines${Platform.pathSeparator}$name';
  @override Stream<EngineEvent> get events => _events.stream;
  void _emit(ConnectionState state, String detail, {bool quality = false, int? speed}) {
    _detail = detail;
    if (!_events.isClosed) _events.add(EngineEvent(state, detail, quality, speed));
  }
  Future<ProcessResult> _run(String program, List<String> args, {int seconds = 15}) async {
    final p = await Process.start(program, args, runInShell: false);
    final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    try {
      final code = await p.exitCode.timeout(Duration(seconds: seconds));
      return ProcessResult(p.pid, code, await out, await err);
    } finally { p.kill(); }
  }
  Future<Map<String, dynamic>> _system(String operation, {String? path}) async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final r = await _run('$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', _file('network.ps1'),
       '-Operation', operation, '-Alias', _alias, if (path != null) ...['-Path', path]]);
    if (r.exitCode != 0) throw StateError('Windows: операция $operation не выполнена (${r.exitCode})');
    final value = r.stdout.toString().trim();
    return value.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }
  Future<void> _verifyBundle() async {
    final manifest = jsonDecode(await File(_file('SHA256.json')).readAsString()) as Map;
    for (final name in ['xray.exe', 'amneziawg.exe', 'wintun.dll', 'network.ps1']) {
      final file = File(_file(name));
      if (!await file.exists() || sha256.convert(await file.readAsBytes()).toString() != manifest[name]) {
        throw StateError('Файлы VPN повреждены. Переустановите Quiet VPN.');
      }
    }
  }
  @override Future<void> initialize() async {
    await _verifyBundle();
    await _system('check');
    final support = await getApplicationSupportDirectory();
    _privateDir = '${support.path}\\tunnel';
    await _system('prepare', path: _privateDir);
    // Stop only our service left by an interrupted previous session.
    await _stopAwg();
    await _system('cleanup');
  }
  Future<void> _stopAwg() async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final existing = await _run('$systemRoot\\System32\\sc.exe', ['query', r'AmneziaWGTunnel$QuietVPN-AWG']);
    if (existing.exitCode == 1060) return;
    await _run(_file('amneziawg.exe'), ['/uninstalltunnelservice', 'QuietVPN-AWG']);
    // Service deletion is asynchronous even when the uninstall process succeeds.
    // Wait until SCM confirms absence before reusing the fixed tunnel name.
    for (var i = 0; i < 30; i++) {
      final check = await _run('$systemRoot\\System32\\sc.exe', ['query', r'AmneziaWGTunnel$QuietVPN-AWG']);
      if (check.exitCode == 1060) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Отключение службы WireGuard не подтверждено');
  }

  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    if (_active || _stopping) throw StateError('Сначала отключите VPN');
    final profile = ProfilePolicy.parse(server.profile);
    await _verifyBundle();
    final token = ++_epoch;
    _protocol = profile.protocol; _active = true; _logBytes = 0;
    _emit(ConnectionState.connecting, 'Windows: запуск ${profile.protocol}');
    try {
      if (profile.protocol == 'wireguard') {
        final file = File('$_privateDir\\QuietVPN-AWG.conf');
        await file.writeAsString(profile.text, flush: true);
        final result = await _run(_file('amneziawg.exe'), ['/installtunnelservice', file.path]);
        if (result.exitCode != 0) throw StateError('Не удалось запустить службу WireGuard (${result.exitCode})');
        final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        final demand = await _run('$systemRoot\\System32\\sc.exe', ['config', r'AmneziaWGTunnel$QuietVPN-AWG', 'start=', 'demand']);
        if (demand.exitCode != 0) throw StateError('Не удалось настроить службу WireGuard');
      } else {
        final addresses = await InternetAddress.lookup(profile.host).timeout(const Duration(seconds: 8));
        if (addresses.isEmpty) throw StateError('DNS сервера недоступен');
        final config = WindowsConfig.xray(profile.text, addresses.first.address);
        final p = await Process.start(_file('xray.exe'), ['run', '-config', 'stdin:'],
          workingDirectory: '$_root\\engines', runInShell: false);
        _xray = p;
        p.stdout.listen((bytes) { _logBytes += bytes.length; });
        p.stderr.listen((bytes) { _logBytes += bytes.length; });
        p.stdin.write(jsonEncode(config)); await p.stdin.flush(); await p.stdin.close();
        unawaited(p.exitCode.then((code) {
          if (identical(_xray, p)) _xray = null;
          if (token == _epoch && !_stopping) {
            _emit(ConnectionState.error, 'Xray завершился, код $code; журнал: $_logBytes байт');
          }
        }));
      }
      unawaited(_verify(token));
    } catch (_) { rethrow; }
  }
  Future<void> _verify(int token) async {
    try {
      Map<String, dynamic> info = {};
      for (var i = 0; i < 15; i++) {
        if (token != _epoch) return;
        info = await _system('tunnel');
        if (info['ready'] == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (token != _epoch) return;
      if (info['ready'] != true) throw StateError('Интерфейс VPN не появился');
      _emit(ConnectionState.connecting, 'Windows: проверка DNS, HTTPS и скорости через VPN');
      final result = await _probe.measure(info['address'] as String);
      if (token != _epoch) return;
      _emit(ConnectionState.connected, result['detail'] as String,
        quality: result['quality'] == true, speed: result['bytesPerSecond'] as int?);
    } catch (e) {
      if (token == _epoch) _emit(ConnectionState.error, 'Windows VPN: ${e is StateError ? e.message : e.runtimeType}');
    }
  }
  @override Future<Map<String, dynamic>> probeTunnel() async {
    if (!_active || _stopping) return {'delay': -1, 'quality': false, 'detail': 'VPN выключен'};
    final info = await _system('tunnel');
    if (info['ready'] != true) return {'delay': -1, 'quality': false, 'detail': 'Нет интерфейса VPN'};
    return _probe.measure(info['address'] as String);
  }
  @override Future<void> disconnect() async {
    _stopping = true; _epoch++; _probe.cancel();
    try {
      if (_protocol == 'wireguard') await _stopAwg();
      final p = _xray;
      if (p != null) { p.kill(); await p.exitCode.timeout(const Duration(seconds: 8)); _xray = null; }
      await _system('cleanup');
      final config = File('$_privateDir\\QuietVPN-AWG.conf');
      if (await config.exists()) await config.delete();
      _active = false;
      _emit(ConnectionState.disconnected, 'VPN отключён');
    } finally { _stopping = false; }
  }
  @override Future<NetworkContext> readNetwork() async => NetworkContext.fromMap(await _system('network'));
  @override Future<TrafficCounters?> readTraffic() async {
    if (!_active || _stopping) return null;
    final info = await _system('tunnel');
    return info['ready'] == true ? TrafficCounters((info['received'] as num).toInt(), (info['sent'] as num).toInt()) : null;
  }
  @override Future<String> diagnostics() async => 'Quiet VPN · Windows ${Platform.operatingSystemVersion}\n'
    'Движки: Xray / AmneziaWG\n$_detail\nЖурнал процесса Xray: $_logBytes байт (содержимое не экспортируется)';
  @override Future<void> reconcile() async {
    if (!_active) return;
    final info = await _system('tunnel');
    if (info['ready'] != true && !_stopping) _emit(ConnectionState.error, 'Интерфейс VPN пропал');
  }
  @override Future<void> dispose() async { if (_active) await disconnect(); await _events.close(); }
}
