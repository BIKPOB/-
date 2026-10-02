import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../core/models.dart';
import '../core/management_protocol.dart';
import 'vpn_engine.dart';

/// Controls one owned foreground OpenVPN process, never arbitrary system tunnels.
/// Uses the official management protocol instead of guessing status from logs.
class WindowsEngine implements VpnEngine {
  WindowsEngine(this.supportDirectory);
  final Directory supportDirectory;
  final _events = StreamController<EngineEvent>.broadcast();
  Process? _process;
  Socket? _socket;
  Directory? _session;
  StreamSubscription<String>? _lines;
  StreamSubscription<List<int>>? _out, _err;
  bool _closing = false;
  bool _disposed = false;
  int _epoch = 0;
  @override Stream<EngineEvent> get events => _events.stream;
  void _emit(EngineEvent event) { if (!_disposed) _events.add(event); }
  String _executable() {
    final bundled = File('${File(Platform.resolvedExecutable).parent.path}/runtime/openvpn.exe');
    if (bundled.existsSync()) return bundled.path;
    final installed = File('${Platform.environment['ProgramW6432'] ?? Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}/OpenVPN/bin/openvpn.exe');
    if (installed.existsSync()) return installed.path;
    throw StateError('Установите OpenVPN Community 2.6+ с драйвером или поставьте runtime рядом с приложением');
  }
  @override Future<void> initialize() async {
    _emit(const EngineEvent(ConnectionState.disconnected));
  }
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    if (_process != null) throw StateError('Сначала отключите активный процесс');
    final executable = _executable();
    _closing = false;
    final epoch = ++_epoch;
    try {
      await supportDirectory.create(recursive: true);
      final dir = await supportDirectory.createTemp('session-');
      _session = dir;
      await _restrictDirectory(dir);
      final random = Random.secure();
      final password = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final secret = File('${dir.path}/management.secret');
      await secret.writeAsString('$password\n', flush: true);
      final profile = File('${dir.path}/connection.ovpn');
      await profile.writeAsString(server.profile, flush: true);
      final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reservation.port;
      await reservation.close();
      final process = await Process.start(executable, [
        '--config', profile.path, '--management', '127.0.0.1', '$port', secret.path,
        '--management-hold', '--management-query-passwords', '--management-signal',
        '--auth-nocache', '--script-security', '1', '--verb', '3',
        '--connect-retry-max', '2', '--connect-timeout', '10',
        '--windows-driver', 'wintun', '--disable-dco', '--block-outside-dns',
      ], runInShell: false, workingDirectory: dir.path);
      _process = process;
      // Drain pipes to prevent deadlock; do not write profile/credential logs.
      _out = process.stdout.listen((_) {});
      _err = process.stderr.listen((_) {});
      unawaited(process.exitCode.then((code) {
        if (epoch == _epoch && !_closing) {
          _emit(EngineEvent(ConnectionState.error,
            'OpenVPN завершился (код $code). Проверьте права, профиль и драйвер.'));
        }
      }));
      Socket? socket;
      for (var i = 0; i < 30; i++) {
        try { socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 300)); break; }
        on SocketException { await Future<void>.delayed(const Duration(milliseconds: 200)); }
      }
      if (socket == null) throw StateError('Management interface недоступен');
      final channel = socket;
      _socket = channel;
      var authenticated = false;
      _lines = channel.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (epoch != _epoch || _closing) return;
        if (line.contains('SUCCESS: password is correct')) {
          authenticated = true;
          channel.write('state on\nhold off\nhold release\n');
        }
        if (!authenticated) return;
        if (line.startsWith(">PASSWORD:Need 'Auth'")) {
          if (credentials == null) {
            _emit(const EngineEvent(ConnectionState.error, 'Нужны логин и пароль')); return;
          }
          try {
            channel.write('username "Auth" ${managementQuote(credentials.username)}\n');
            channel.write('password "Auth" ${managementQuote(credentials.password)}\n');
          } catch (_) { _emit(const EngineEvent(ConnectionState.error, 'Некорректные учётные данные')); }
        } else if (line.startsWith('>PASSWORD:Need')) {
          _emit(const EngineEvent(ConnectionState.error, 'Зашифрованный private key пока не поддерживается'));
        }
        final event = parseManagementState(line);
        if (event != null) _emit(event);
      }, onError: (_) {
        if (!_closing) _emit(const EngineEvent(ConnectionState.error, 'Связь с OpenVPN потеряна'));
      }, onDone: () {
        if (!_closing && epoch == _epoch) _emit(const EngineEvent(ConnectionState.error, 'OpenVPN отключился'));
      });
      channel.write('$password\n');
      _emit(const EngineEvent(ConnectionState.connecting));
    } catch (_) { await disconnect(); rethrow; }
  }

  Future<void> _restrictDirectory(Directory dir) async {
    final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final who = await Process.run('$system/System32/whoami.exe', ['/user', '/fo', 'csv', '/nh']);
    final sid = RegExp(r'S-1-5-[0-9-]+').firstMatch(who.stdout.toString())?.group(0);
    if (sid == null) throw StateError('Не удалось определить владельца профиля');
    final result = await Process.run('$system/System32/icacls.exe', [dir.path, '/inheritance:r',
      '/grant:r', '*$sid:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F']);
    if (result.exitCode != 0) throw StateError('Не удалось защитить временный профиль');
  }

  @override Future<void> disconnect() async {
    _closing = true;
    final process = _process;
    if (process != null) {
      try { _socket?.write('signal SIGTERM\n'); await _socket?.flush(); } catch (_) { /* process may have exited */ }
      try { await process.exitCode.timeout(const Duration(seconds: 8)); }
      on TimeoutException {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
    _epoch++;
    await _lines?.cancel(); _lines = null;
    _socket?.destroy(); _socket = null;
    await _out?.cancel(); await _err?.cancel(); _out = null; _err = null;
    _process = null;
    final session = _session;
    if (session != null && await session.exists()) await session.delete(recursive: true);
    _session = null;
    _emit(const EngineEvent(ConnectionState.disconnected));
  }
  @override Future<void> reconcile() async { /* Owned process reports native events continuously. */ }
  @override Future<void> dispose() async {
    await disconnect(); _disposed = true; await _events.close();
  }
}
