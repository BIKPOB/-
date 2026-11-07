import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/models.dart';
import '../core/proxy_profile.dart';
import '../core/traffic.dart';
import 'vpn_engine.dart';
import 'candidate_host.dart';

class AndroidEngine implements VpnEngine, TrafficSource, ReserveCandidateHost,
    QuickProbeSupport, SearchSessionHost {
  static const _wg = MethodChannel('quietvpn/wg');
  static const _xray = MethodChannel('flutter_v2ray_client');
  static const _stage = MethodChannel('quietvpn/xray-state');
  static const _searchSession = MethodChannel('quietvpn/search-session');
  final _events = StreamController<EngineEvent>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String _active = 'wireguard', _xrayState = 'DISCONNECTED';
  TrafficCounters? _counters;
  bool _stopping = false, _checking = false, _verified = false, _disposed = false,
      _starting = false, _quickProbe = false;
  int _epoch = 0;
  @override void setQuickProbe(bool enabled) => _quickProbe = enabled;
  @override Future<void> beginSearchSession({required bool deep}) =>
      _searchSession.invokeMethod<void>('start', {'deep':deep});
  @override Future<void> endSearchSession() =>
      _searchSession.invokeMethod<void>('stop');
  @override Stream<EngineEvent> get events => _events.stream;
  void _emit(ConnectionState state, [String? detail, bool quality = true,
    int? bytesPerSecond, bool httpsVerified = false]) {
    if (!_disposed) _events.add(EngineEvent(state, detail, quality, bytesPerSecond, null, httpsVerified));
  }
  @override Future<void> initialize() async {
    _subscriptions.add(const EventChannel('quietvpn/wg-events').receiveBroadcastStream().listen((s) {
      if (_active == 'wireguard' && !_stopping) _wgEvent(s);
    }, onError: (_) => _emit(ConnectionState.error, 'Ошибка WireGuard')));
    _subscriptions.add(const EventChannel('flutter_v2ray_client/status').receiveBroadcastStream().listen((dynamic data) {
      if (data is! List || data.length < 6) return;
      _xrayState = data[5].toString();
      _counters = TrafficCounters(int.tryParse(data[4].toString()) ?? 0, int.tryParse(data[3].toString()) ?? 0);
      if (_active == 'wireguard' && !_starting && _xrayState == 'CONNECTED') _active = 'vless';
      if (_active != 'wireguard' && !_stopping) _proxyEvent();
    }, onError: (_) => _emit(ConnectionState.error, 'Ошибка Xray')));
    await _xray.invokeMethod<void>('initializeV2Ray', {'notificationIconResourceType':'drawable',
      'notificationIconResourceName':'ic_stat_quiet', 'providerBundleIdentifier':'', 'groupIdentifier':''});
    await reconcile();
  }
  void _wgEvent(dynamic stage) {
    if (_starting && stage == 'disconnected') return;
    if (stage != 'connecting') _starting = false;
    _emit(switch (stage) {
    'connected' => ConnectionState.connected, 'connecting' => ConnectionState.connecting,
    'error' => ConnectionState.error, _ => ConnectionState.disconnected,
  });
  }
  void _proxyEvent() {
    if (_xrayState == 'CONNECTED') {
      _starting = false;
      if (_verified) return;
      if (!_checking) unawaited(_verifyProxy());
    } else if (_xrayState == 'CONNECTING') {
      _emit(ConnectionState.connecting, 'Запуск Xray');
    } else if (_xrayState == 'DISCONNECTED' && !_starting) {
      _epoch++; _verified = false;
      _emit(ConnectionState.disconnected);
    }
  }
  Future<void> _verifyProxy() async {
    _checking = true;
    final epoch = _epoch;
    _emit(ConnectionState.connecting, _quickProbe
      ? 'Проверка HTTPS через системный VPN (без замера скорости)'
      : 'Xray запущен локально · проверка удалённого соединения (DNS и загрузка данных)');
    try {
      final quick = _quickProbe;
      // Quick search proves app traffic over the real system VPN, not just a
      // local SOCKS listener which could succeed while the TUN route is broken.
      final probe = await _stage.invokeMapMethod<String, dynamic>(
          quick ? 'tunnelProbe' : 'probe', {'quick':quick})
          .timeout(Duration(seconds: quick ? 8 : 35));
      final delay = (probe?['delay'] as num?)?.toInt();
      final detail = probe?['detail'] as String? ?? 'Нет результата проверки';
      if (_stopping || epoch != _epoch || _disposed) return;
      _verified = true; // A status tick should not restart the same probe.
      if (delay == null || delay < 0) {
        _emit(ConnectionState.connected, 'Туннель включён, интернет НЕ подтверждён. '
          'Проверка через Xray не прошла: $detail', false);
      } else {
        _emit(ConnectionState.connected, '$detail · $delay мс',
          probe?['quality'] == true, (probe?['bytesPerSecond'] as num?)?.toInt(), true);
        if (quick) unawaited(_measureSpeedAfterQuick(epoch));
      }
    } catch (_) {
      if (!_stopping && epoch == _epoch && !_disposed) {
        _verified = true;
        _emit(ConnectionState.connected, 'Туннель включён, интернет НЕ подтверждён: таймаут проверки Xray', false);
      }
    } finally { _checking = false; }
  }
  Future<void> _measureSpeedAfterQuick(int epoch) async {
    // The optional transfer must never delay the 15-second quick search.
    // No false speed is reported if this secondary endpoint is blocked.
    try {
      final result = await _stage.invokeMapMethod<String, dynamic>(
        'tunnelProbe', {'quick':false}).timeout(const Duration(seconds: 40));
      if (_stopping || epoch != _epoch || _disposed || (result?['delay'] as num? ?? -1) < 0) return;
      final bps = (result?['bytesPerSecond'] as num?)?.toInt();
      _emit(ConnectionState.connected,
        result?['detail'] as String? ?? 'HTTPS подтверждён · замер скорости',
        result?['quality'] == true, bps, true);
    } catch (_) { /* Keep the verified connection; speed remains unknown. */ }
  }
  String? _labConfiguration;
  static const _lab = MethodChannel('quietvpn/candidate-lab');
  @override Future<String> resolveCandidate(String host) async =>
    (await _lab.invokeMethod<String>('resolve', {'host':host})) ?? (throw StateError('Нет адреса'));
  @override Future<void> startReserveCandidates(String configuration) async {
    if (_starting || _stopping || _active == 'wireguard' || _xrayState != 'CONNECTED') throw StateError('Резерв требует активного Xray');
    _labConfiguration=configuration;
    await _lab.invokeMethod<void>('reserveStart', {'config':configuration});
    await CandidatePorts.wait(configuration);
  }
  @override Future<void> startCandidates(String configuration) async {
    if (_starting || _xrayState != 'DISCONNECTED') throw StateError('VPN уже активен');
    _labConfiguration=configuration;
    try {
      await _lab.invokeMethod<void>('start', {'config':configuration});
    } on PlatformException catch (e) {
      throw CandidateStartException(e.code);
    }
    await CandidatePorts.wait(configuration);
  }
  @override Future<void> stopCandidates() async {
    await _lab.invokeMethod<void>('stop');
    final config=_labConfiguration;
    if(config!=null) await CandidatePorts.closed(config);
    _labConfiguration=null;
  }
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    final token = ++_epoch;
    await stopCandidates();
    if (token != _epoch || _stopping) return;
    _verified = false; _counters = null; _active = server.protocol; _starting = true;
    await Permission.notification.request();
    if (token != _epoch || _stopping) return;
    if (_active == 'wireguard') {
      await _wg.invokeMethod<void>('start', {'profile':server.profile}); return;
    }
    if (!{'vless','shadowsocks'}.contains(_active)) throw StateError('Протокол не поддерживается');
    final bypass = await const MethodChannel('quietvpn/app-routing').invokeListMethod<String>('selected') ?? <String>[];
    final logPath = await _stage.invokeMethod<String>('prepareDiagnostics');
    _emit(ConnectionState.connecting, 'Разрешение адреса VPN-сервера до запуска туннеля');
    final endpoint = await _stage.invokeMethod<String>('resolveEndpoint', {'host': server.host, 'port': server.port}).timeout(const Duration(seconds: 15));
    if (token != _epoch || _stopping) return;
    if (endpoint == null) throw StateError('DNS: не удалось разрешить адрес VPN-сервера');
    final config = ProxyProfile.parse(server.profile).configurationWithDiagnostics(errorLogPath: logPath, endpointAddress: endpoint);
    if (await _xray.invokeMethod<bool>('requestPermission') != true) throw StateError('Разрешение VPN отклонено');
    if (token != _epoch || _stopping) return;
    _xrayState = 'CONNECTING';
    _emit(ConnectionState.connecting, 'Запуск ${server.protocol.toUpperCase()}');
    await _xray.invokeMethod<void>('startV2Ray', {'remark':'Quiet VPN', 'config':config,
      'blocked_apps':bypass, 'bypass_subnets':null, 'proxy_only':false, 'notificationDisconnectButtonName':'Отключить'});
    if (token != _epoch) await _xray.invokeMethod<void>('stopV2Ray');
  }
  @override Future<void> disconnect() async {
    _stopping = true; _starting = false; _epoch++; _verified = false;
    try {
      // Do not let an unrelated candidate-lab shutdown or stalled diagnostic
      // RPC block the actual system VPN stop button.
      try { await stopCandidates().timeout(const Duration(seconds: 2)); } catch (_) {}
      try {
        await _stage.invokeMethod<void>('cancelProbe').timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (_active == 'wireguard') {
        await _wg.invokeMethod<void>('stop').timeout(const Duration(seconds: 5));
      } else {
        await _xray.invokeMethod<void>('stopV2Ray').timeout(const Duration(seconds: 5));
        var stopped = false;
        for (var i = 0; i < 20; i++) {
          final stage = await _stage.invokeMethod<String>('stage')
              .timeout(const Duration(milliseconds: 600));
          if (stage == 'DISCONNECTED') {
            _xrayState = 'DISCONNECTED'; stopped = true; break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!stopped) throw StateError('Отключение Xray не подтверждено');
      }
      // Never report a clean disconnect while Android still routes via our
      // VPN. Keep stop retryable if the native service fails to tear down.
      for (var i = 0; i < 20; i++) {
        Map<dynamic, dynamic>? snapshot;
        try {
          snapshot = await const MethodChannel('quietvpn/catalog-cache')
              .invokeMapMethod<dynamic, dynamic>('networkContext')
              .timeout(const Duration(milliseconds: 800));
        } on MissingPluginException { break; }
        if (snapshot?['ownVpn'] != true) break;
        if (i == 19) throw StateError('Системный маршрут Quiet VPN ещё отключается');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _counters = null; _emit(ConnectionState.disconnected);
    } finally { _stopping = false; }
  }
  @override Future<void> reconcile() async {
    if (_starting) return;
    final wg = await _wg.invokeMethod<String>('stage');
    if (wg == 'connected' || wg == 'connecting') { _active = 'wireguard'; _wgEvent(wg); return; }
    _xrayState = await _stage.invokeMethod<String>('stage') ?? 'DISCONNECTED';
    if (_xrayState != 'DISCONNECTED') { _active = 'vless'; _proxyEvent(); }
    else if (!_stopping && !_starting) { _emit(ConnectionState.disconnected); }
  }
  @override Future<TrafficCounters?> readTraffic() async {
    if (_active != 'wireguard') return _verified ? _counters : null;
    final data = await _wg.invokeMapMethod<String, dynamic>('traffic');
    return data == null ? null : TrafficCounters(data['received'] as int, data['sent'] as int);
  }
  @override Future<void> dispose() async {
    await stopCandidates();
    _disposed = true; _epoch++;
    for (final subscription in _subscriptions) { await subscription.cancel(); }
    await _events.close();
  }
}
