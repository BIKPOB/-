import 'dart:async';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/models.dart';
import 'vpn_engine.dart';

class AndroidEngine implements VpnEngine {
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
    if (state != null) _events.add(EngineEvent(state,
      stage == VPNStage.denied ? 'Разрешение VPN отклонено' : null));
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
