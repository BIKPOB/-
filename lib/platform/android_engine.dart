import 'package:flutter/services.dart';
import 'dart:async';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/models.dart';
import 'vpn_engine.dart';

class OpenVpnAndroidEngine implements VpnEngine {
  final _events = StreamController<EngineEvent>.broadcast();
  late final OpenVPN _native = OpenVPN(onVpnStageChanged: (stage, _) => _stage(stage));
  bool _disposed = false;
  @override Stream<EngineEvent> get events => _events.stream;
  void _stage(VPNStage stage) {
    if (_disposed) return;
    final state = switch (stage) {
      VPNStage.connected => ConnectionState.connected,
      VPNStage.disconnected => ConnectionState.disconnected,
      VPNStage.denied || VPNStage.error => ConnectionState.error,
      VPNStage.unknown => null,
      _ => ConnectionState.connecting,
    };
    if (state != null) {
      _events.add(EngineEvent(state,
        stage == VPNStage.denied ? 'Разрешение VPN отклонено' : null));
    }
  }
  @override Future<void> initialize() async {
    await _native.initialize(localizedDescription: 'Quiet VPN', lastStage: _stage);
    await reconcile();
  }
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    await Permission.notification.request();
    await _native.connect(server.profile, '${server.country} • ${server.name}',
      username: credentials?.username, password: credentials?.password,
      certIsRequired: true); // Do not append a server-side client-cert-not-required directive.
  }
  @override Future<void> disconnect() async {
    _native.disconnect();
    for (var i = 0; i < 30; i++) {
      final stage = await _native.stage();
      if (stage == VPNStage.disconnected) {
        _events.add(const EngineEvent(ConnectionState.disconnected));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Система ещё не подтвердила отключение');
  }
  @override Future<void> reconcile() async => _stage(await _native.stage());
  @override Future<void> dispose() async { _disposed = true; await _events.close(); }
}


class AndroidEngine implements VpnEngine {
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
