import 'package:flutter/services.dart';
import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import '../core/models.dart';
import '../core/traffic.dart';
import 'vpn_engine.dart';

class OpenVpnAndroidEngine implements VpnEngine {
  final _events = StreamController<EngineEvent>.broadcast();
  static const _channel = MethodChannel('quietvpn/openvpn');
  StreamSubscription<dynamic>? _subscription;
  @override Stream<EngineEvent> get events => _events.stream;
  void _stage(dynamic stage) {
    final detail = stage is Map ? stage['detail'] as String? : null;
    final value = stage is Map ? stage['state'] : stage;
    _events.add(EngineEvent(switch (value) {
      'connected' => ConnectionState.connected,
      'connecting' => ConnectionState.connecting,
      'error' => ConnectionState.error,
      _ => ConnectionState.disconnected,
    }, detail));
  }
  @override Future<void> initialize() async {
    _subscription = const EventChannel('quietvpn/openvpn-events').receiveBroadcastStream().listen(_stage,
      onError: (_) => _events.add(const EngineEvent(ConnectionState.error, 'Ошибка OpenVPN')));
    await reconcile();
  }
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    await Permission.notification.request();
    await _channel.invokeMethod<void>('start', {'profile': server.profile,
      'name': '${server.country} • ${server.name}',
      'username': credentials?.username, 'password': credentials?.password});
  }
  @override Future<void> disconnect() async {
    await _channel.invokeMethod<void>('stop');
    for (var i = 0; i < 30; i++) {
      final stage = await _channel.invokeMethod<String>('stage');
      if (stage == 'disconnected') { _stage(stage); return; }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Система ещё не подтвердила отключение');
  }
  @override Future<void> reconcile() async => _stage(await _channel.invokeMethod<String>('stage'));
  @override Future<void> dispose() async { await _subscription?.cancel(); await _events.close(); }
}


class AndroidEngine implements VpnEngine, TrafficSource {
  @override Future<TrafficCounters?> readTraffic() async {
    final channel = _active == 'openvpn' ? const MethodChannel('quietvpn/openvpn') : _channel;
    final data = await channel.invokeMapMethod<String, dynamic>('traffic');
    if (data == null) return null;
    return TrafficCounters(data['received'] as int, data['sent'] as int);
  }
  final _openvpn = OpenVpnAndroidEngine();
  static const _channel = MethodChannel('quietvpn/wg');
  static const _nativeEvents = EventChannel('quietvpn/wg-events');
  final _events = StreamController<EngineEvent>.broadcast();
  StreamSubscription<EngineEvent>? _ovpnSubscription;
  StreamSubscription<dynamic>? _wgSubscription;
  String _active = 'openvpn';
  @override Stream<EngineEvent> get events => _events.stream;
  void _wgEvent(dynamic stage) {
    if (_active == 'openvpn') return;
    final state = switch (stage) {
      'connected' => ConnectionState.connected,
      'connecting' => ConnectionState.connecting,
      'error' => ConnectionState.error,
      _ => ConnectionState.disconnected,
    };
    _events.add(EngineEvent(state));
  }
  @override Future<void> initialize() async {
    _ovpnSubscription = _openvpn.events.listen((event) { if (_active == 'openvpn') _events.add(event); });
    _wgSubscription = _nativeEvents.receiveBroadcastStream().listen(_wgEvent,
      onError: (_) { if (_active != 'openvpn') _events.add(const EngineEvent(ConnectionState.error, 'Ошибка VPN-движка')); });
    final stage = await _channel.invokeMethod<String>('stage');
    if (stage == 'connecting' || stage == 'connected') _active = 'amneziawg';
    await _openvpn.initialize();
    if (_active != 'openvpn') _wgEvent(stage);
  }
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    _active = server.protocol;
    if (_active == 'openvpn') { await _openvpn.connect(server, credentials); return; }
    if (!{'wireguard', 'amneziawg'}.contains(_active)) throw StateError('Неподдерживаемый протокол');
    await Permission.notification.request();
    await _channel.invokeMethod<void>('start', {'profile': server.profile});
  }
  @override Future<void> disconnect() async {
    if (_active == 'openvpn') { await _openvpn.disconnect(); }
    else { await _channel.invokeMethod<void>('stop'); }
  }
  @override Future<void> reconcile() async {
    if (_active == 'openvpn') { await _openvpn.reconcile(); }
    else { _wgEvent(await _channel.invokeMethod<String>('stage')); }
  }
  @override Future<void> dispose() async {
    await _ovpnSubscription?.cancel(); await _wgSubscription?.cancel();
    await _openvpn.dispose(); await _events.close();
  }
}
