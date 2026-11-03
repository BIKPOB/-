import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';
import '../core/network_context.dart';
import '../core/profile_policy.dart';
import '../core/traffic.dart';
import 'desktop_capabilities.dart';
import 'vpn_engine.dart';
import 'candidate_host.dart';
import 'windows_config.dart';
import '../core/xray_failure.dart';
import 'windows_probe.dart';
import '../core/site_bypass.dart';

class WindowsEngine implements VpnEngine, TrafficSource, DesktopCapabilities, ReserveCandidateHost, SiteBypassHost {
  final _events = StreamController<EngineEvent>.broadcast();
  final _probe = WindowsProbe();
  final _root = File(Platform.resolvedExecutable).parent.path;
  File? _bypassFile;
  List<String> _bypassSites = [];
  @override List<String> get bypassSites => List.unmodifiable(_bypassSites);
  @override Future<void> saveBypassSites(List<String> sites) async {
    final normalized = SiteBypass.parse(sites.join('\n'));
    final file = _bypassFile;
    if (file == null) throw StateError('Настройки ещё не загружены');
    await file.writeAsString(jsonEncode(normalized), flush: true);
    _bypassSites = normalized;
  }
  Process? _xray;
  bool _active = false, _stopping = false;
  int _epoch = 0, _logBytes = 0;
  final _errors = <String>{};
  String _logTail = '';
  void _capture(List<int> bytes) {
    _logBytes += bytes.length;
    final text = utf8.decode(bytes, allowMalformed: true).toLowerCase();
    final combined = _logTail + text;
    final reason = XrayFailure.explain(combined);
    if (reason != null) _errors.add(reason);
    _logTail = combined.substring(max(0, combined.length - 512));
    const categories = {'failed to build': 'Ошибка конфигурации', 'failed to load': 'Ошибка загрузки конфигурации', 'failed to start': 'Ошибка запуска Xray', 'failed': 'Xray сообщил об ошибке запуска/соединения', 'invalid': 'Некорректные параметры/ответ', 'unsupported': 'Неподдерживаемый параметр', 'timeout': 'Таймаут', 'deadline exceeded': 'Таймаут операции', 'connection refused': 'Сервер отказал', 'connection reset': 'Соединение сброшено', 'no such host': 'DNS не разрешён', 'certificate': 'Ошибка сертификата', 'bad handshake': 'Ошибка согласования', 'eof': 'Соединение закрыто'};
    for (final entry in categories.entries) { if (text.contains(entry.key)) _errors.add(entry.value); }
  }
  String get _errorSummary => _errors.isEmpty ? 'Причина не классифицирована' : _errors.join('; ');
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
    _bypassFile = File('${support.path}\\site-bypass.json');
    if (await _bypassFile!.exists()) {
      _bypassSites = SiteBypass.parse((jsonDecode(await _bypassFile!.readAsString()) as List).cast<String>().join('\n'));
    }
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

  Future<void> _validateConfig(Map<String, dynamic> config) async {
    final p = await Process.start(_file('xray.exe'), ['run', '-test', '-config', 'stdin:'],
      workingDirectory: '$_root\\engines', runInShell: false);
    final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    try {
      p.stdin.write(jsonEncode(config));
      await p.stdin.flush(); await p.stdin.close();
      final code = await p.exitCode.timeout(const Duration(seconds: 8));
      final logs = '${await out}\n${await err}';
      if (code != 0) {
        throw StateError('Xray: проверка конфигурации до запуска VPN: ${XrayFailure.explain(logs) ?? "конфигурация отклонена"} (код $code)');
      }
    } finally { p.kill(); }
  }

  Process? _candidateCore;
  @override Future<String> resolveCandidate(String host) async {
    final addresses=await InternetAddress.lookup(host);
    if(addresses.isEmpty) throw StateError('Нет адреса');
    return addresses.firstWhere((a)=>a.type==InternetAddressType.IPv4,orElse:()=>addresses.first).address;
  }
  @override Future<void> startReserveCandidates(String configuration) async {
    if (!_active || _stopping || _protocol == 'wireguard') throw StateError('Резерв доступен только при активном Xray');
    final network = await _system('network');
    if (network['ambiguous'] == true || network['foreignVpn'] != false || network['physicalInterface'] is! String) {
      throw StateError('Независимый маршрут резерва не подтверждён');
    }
    final config = Map<String,dynamic>.from(jsonDecode(configuration) as Map);
    for (final outbound in config['outbounds'] as List) {
      if (outbound['protocol'] == 'blackhole') continue;
      final stream = outbound.putIfAbsent('streamSettings', () => <String,dynamic>{}) as Map;
      final options = stream.putIfAbsent('sockopt', () => <String,dynamic>{}) as Map;
      options['interface'] = network['physicalInterface'];
    }
    await _startCandidateProcess(jsonEncode(config));
  }
  @override Future<void> startCandidates(String configuration) async {
    if(_active || _stopping) throw StateError('VPN уже активен');
    await _startCandidateProcess(configuration);
  }
  Future<void> _startCandidateProcess(String configuration) async {
    await stopCandidates();
    await _verifyBundle();
    await _validateConfig(Map<String,dynamic>.from(jsonDecode(configuration) as Map));
    final p=await Process.start(_file('xray.exe'), ['run','-config','stdin:'],
      workingDirectory:'$_root\\engines',runInShell:false);
    _candidateCore=p;
    unawaited(p.stdout.drain<void>());unawaited(p.stderr.drain<void>());
    p.stdin.write(configuration);await p.stdin.flush();await p.stdin.close();
    await CandidatePorts.wait(configuration);
    if(await p.exitCode.timeout(const Duration(milliseconds:1),onTimeout:()=>-9999)!=-9999) {
      throw StateError('Проверочный Xray завершился');
    }
  }
  @override Future<void> stopCandidates() async {
    final p=_candidateCore;_candidateCore=null;
    if(p!=null) {p.kill();await p.exitCode.timeout(const Duration(seconds:3));}
  }

  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    final token = ++_epoch;
    await stopCandidates();
    if (token != _epoch) return;
    if (_active || _stopping) throw StateError('Сначала отключите VPN');
    final profile = ProfilePolicy.parse(server.profile);
    if (profile.protocol == 'wireguard' && _bypassSites.isNotEmpty) {
      throw StateError('Исключения сайтов поддерживают VLESS/Shadowsocks. Выберите такой сервер или очистите список исключений.');
    }
    await _verifyBundle();
    if (token != _epoch) return;
    _protocol = profile.protocol; _active = true; _logBytes = 0; _errors.clear(); _logTail = '';
    _emit(ConnectionState.connecting, 'Windows: запуск ${profile.protocol}');
    try {
      if (profile.protocol == 'wireguard') {
        final file = File('$_privateDir\\QuietVPN-AWG.conf');
        await file.writeAsString(profile.text, flush: true);
        if (token != _epoch) return;
        final result = await _run(_file('amneziawg.exe'), ['/installtunnelservice', file.path]);
        if (token != _epoch) { await _stopAwg(); return; }
        if (result.exitCode != 0) throw StateError('Не удалось запустить службу WireGuard (${result.exitCode})');
        final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        final demand = await _run('$systemRoot\\System32\\sc.exe', ['config', r'AmneziaWGTunnel$QuietVPN-AWG', 'start=', 'demand']);
        if (demand.exitCode != 0) throw StateError('Не удалось настроить службу WireGuard');
      } else {
        final addresses = await InternetAddress.lookup(profile.host).timeout(const Duration(seconds: 8));
        if (addresses.isEmpty) throw StateError('DNS сервера недоступен');
        final config = WindowsConfig.xray(profile.text, addresses.first.address, bypassSites: _bypassSites);
        await _validateConfig(config);
        if (token != _epoch) return;
        final p = await Process.start(_file('xray.exe'), ['run', '-config', 'stdin:'],
          workingDirectory: '$_root\\engines', runInShell: false);
        if (token != _epoch) { p.kill(); await p.exitCode; return; }
        _xray = p;
        p.stdout.listen(_capture);
        p.stderr.listen(_capture);
        p.stdin.write(jsonEncode(config)); await p.stdin.flush(); await p.stdin.close();
        unawaited(p.exitCode.then((code) {
          if (identical(_xray, p)) _xray = null;
          if (token == _epoch && !_stopping) {
            _emit(ConnectionState.error, 'Xray завершился, код $code; журнал: $_logBytes байт; $_errorSummary');
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
      if ((result['delay'] as num? ?? -1) < 0) {
        _emit(ConnectionState.error, result['detail'] as String);
        return;
      }
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
      await stopCandidates();
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
  @override Future<void> dispose() async {
    await stopCandidates(); if (_active) await disconnect(); await _events.close(); }
}
