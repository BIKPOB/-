import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/data/profile_store.dart';
import 'package:quiet_vpn/platform/vpn_engine.dart';
import 'package:quiet_vpn/viewmodels/vpn_view_model.dart';

const server = VpnServer(id: 'fixture', name: 'fixture', country: 'Test', countryCode: 'US',
  host: '8.8.8.8', port: 443, transport: 'tcp', source: 'test',
  protocol: 'vless', profile: 'vless://12345678-1234-1234-1234-123456789abc@8.8.8.8:443?security=none');

class MemoryProfiles extends ProfileStore {
  @override Future<List<VpnServer>> load() async => [server];
  @override Future<Credentials?> credentials(String id) async => null;
}
class ControlledEngine implements VpnEngine {
  final controller = StreamController<EngineEvent>.broadcast();
  final started = Completer<void>();
  final release = Completer<void>();
  int connects = 0, disconnects = 0;
  @override Stream<EngineEvent> get events => controller.stream;
  @override Future<void> initialize() async {}
  @override Future<void> reconcile() async {}
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    connects++; started.complete(); await release.future;
  }
  @override Future<void> disconnect() async { disconnects++; }
  @override Future<void> dispose() => controller.close();
}

void main() {
  test('native permission errors retain an actionable message', () async {
    final engine = ControlledEngine();
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize();
      final attempt = vm.connect(null);
      await engine.started.future;
      engine.release.completeError(PlatformException(code: 'permission', message: 'Разрешение VPN отклонено'));
      await attempt;
      expect(vm.state, ConnectionState.error);
      expect(vm.message, 'Разрешение VPN отклонено');
      expect(engine.disconnects, 1);
    } finally { vm.dispose(); await engine.dispose(); }
  });
  test('double connect is dropped while the native start is in progress', () async {
    final engine = ControlledEngine();
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize();
      final first = vm.connect(null);
      await engine.started.future;
      await vm.connect(null);
      expect(engine.connects, 1);
      engine.release.complete(); await first;
      await vm.disconnect();
      expect(vm.state, ConnectionState.disconnected);
      expect(vm.canDisconnect, isFalse);
    } finally { vm.dispose(); await engine.dispose(); }
  });
  test('native error during start is cleaned up after start returns, not concurrently', () async {
    final engine = ControlledEngine();
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize();
      final attempt = vm.connect(null);
      await engine.started.future;
      engine.controller.add(const EngineEvent(ConnectionState.error, 'fixture failure'));
      await Future<void>.delayed(Duration.zero);
      expect(engine.disconnects, 0);
      engine.release.complete(); await attempt;
      expect(engine.disconnects, 1);
      expect(vm.state, ConnectionState.error);
      expect(vm.canDisconnect, isFalse);
    } finally { vm.dispose(); await engine.dispose(); }
  });
}
