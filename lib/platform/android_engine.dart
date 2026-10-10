import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/models.dart';
import '../core/proxy_profile.dart';
import '../core/traffic.dart';
import 'vpn_engine.dart';

class AndroidEngine implements VpnEngine, TrafficSource {
  static const _wg = MethodChannel('quietvpn/wg');
  static const _xray = MethodChannel('flutter_v2ray_client');
  static const _stage = MethodChannel('quietvpn/xray-state');
  final _events = StreamController<EngineEvent>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String _active = 'wireguard', _xrayState = 'DISCONNECTED';
  TrafficCounters? _counters;
  bool _stopping = false, _checking = false, _verified = false, _disposed = false, _starting = false;
  int _epoch = 0;
  @override Stream<EngineEvent> get events => _events.stream;
  void _emit(ConnectionState state, [String? detail]) { if (!_disposed) _events.add(EngineEvent(state, detail)); }
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
    await _xray.invokeMethod<void>('initializeV2Ray', {'notificationIconResourceType':'mipmap',
      'notificationIconResourceName':'ic_launcher', 'providerBundleIdentifier':'', 'groupIdentifier':''});
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
    _emit(ConnectionState.connecting, 'Туннель Xray запущен · проверка ответа через сервер');
    try {
      final delay = await _xray.invokeMethod<int>('getConnectedServerDelay',
        {'url':'https://www.gstatic.com/generate_204'}).timeout(const Duration(seconds: 20));
      if (_stopping || epoch != _epoch || _disposed) return;
      if (delay == null || delay < 0) {
        _emit(ConnectionState.error, 'Xray запущен, но запрос через сервер не прошёл. Проверьте ключ, сервер и сеть.');
      } else { _verified = true; _emit(ConnectionState.connected, 'Ответ через сервер: $delay мс'); }
    } catch (_) {
      if (!_stopping && epoch == _epoch) _emit(ConnectionState.error, 'Таймаут проверки Xray через сервер');
    } finally { _checking = false; }
  }
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    _epoch++; _verified = false; _counters = null; _active = server.protocol; _starting = true;
    await Permission.notification.request();
    if (_active == 'wireguard') {
      await _wg.invokeMethod<void>('start', {'profile':server.profile}); return;
    }
    if (!{'vless','shadowsocks'}.contains(_active)) throw StateError('Протокол не поддерживается');
    final config = ProxyProfile.parse(server.profile).configuration;
    if (await _xray.invokeMethod<bool>('requestPermission') != true) throw StateError('Разрешение VPN отклонено');
    _xrayState = 'CONNECTING';
    _emit(ConnectionState.connecting, 'Запуск ${server.protocol.toUpperCase()}');
    await _xray.invokeMethod<void>('startV2Ray', {'remark':'Quiet VPN', 'config':config,
      'blocked_apps':null, 'bypass_subnets':null, 'proxy_only':false, 'notificationDisconnectButtonName':'Отключить'});
  }
  @override Future<void> disconnect() async {
    _stopping = true; _starting = false; _epoch++; _verified = false;
    try {
      if (_active == 'wireguard') { await _wg.invokeMethod<void>('stop'); }
      else {
        await _xray.invokeMethod<void>('stopV2Ray');
        for (var i = 0; i < 40; i++) {
          final stage = await _stage.invokeMethod<String>('stage');
          if (stage == 'DISCONNECTED') { _xrayState = 'DISCONNECTED'; break; }
          if (i == 39) throw StateError('Отключение Xray не подтверждено');
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
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
    _disposed = true; _epoch++;
    for (final subscription in _subscriptions) { await subscription.cancel(); }
    await _events.close();
  }
}
