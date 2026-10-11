import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/data/profile_store.dart';
import 'package:quiet_vpn/data/public_catalog.dart';
import 'package:quiet_vpn/platform/vpn_engine.dart';
import 'package:quiet_vpn/viewmodels/vpn_view_model.dart';

const server = VpnServer(id: 'fixture', name: 'fixture', country: 'Test', countryCode: 'US',
  host: '8.8.8.8', port: 443, transport: 'tcp', source: 'test',
  protocol: 'vless', profile: 'vless://12345678-1234-1234-1234-123456789abc@8.8.8.8:443?security=none');

class MemoryProfiles extends ProfileStore {
  @override Future<List<VpnServer>> load() async => [server];
  @override Future<String?> loadSelector() async => null;
  @override Future<void> saveSelector(String value) async {}
  @override Future<void> save(List<VpnServer> servers) async {}
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

class SlowFirstEngine extends ControlledEngine {
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    connects++;
    controller.add(EngineEvent(ConnectionState.connected, 'VPN transfer test', connects > 1));
  }
}
class AutoEngine extends ControlledEngine {
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    connects++;
    controller.add(EngineEvent(connects == 1 ? ConnectionState.error : ConnectionState.connected,
      connects == 1 ? 'transport failure' : 'HTTPS verified'));
  }
}
void main() {
  test('auto selection retries a failed tunnel then stops on verified HTTPS', () async {
    final engine = AutoEngine();
    final other = VpnServer.fromJson({...server.toJson(), 'id': 'second', 'host': '9.9.9.9',
      'profile': server.profile.replaceAll('8.8.8.8', '9.9.9.9')});
    final monitor = ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1));
    final vm = VpnViewModel(engine, MemoryProfiles(), monitor,
      catalogLoader: () async => PublicCatalogResult([other], false, 0), networkReader: () async => 'wifi',
      autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize(); await vm.autoConnect();
      expect(engine.connects, 2);
      expect(engine.disconnects, 1);
      expect(vm.connectionVerified, true);
      expect(vm.state, ConnectionState.connected);
      expect(vm.autoSelecting, false);
      await vm.disconnect();
    } finally { vm.dispose(); await engine.dispose(); }
  });
  test('auto selection skips a connected server whose transfer quality is insufficient', () async {
    final engine = SlowFirstEngine();
    final other = VpnServer.fromJson({...server.toJson(), 'id': 'fast', 'host': '9.9.9.9',
      'profile': server.profile.replaceAll('8.8.8.8', '9.9.9.9')});
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () async => PublicCatalogResult([other], false, 0), networkReader: () async => 'wifi',
      autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize(); await vm.autoConnect();
      expect(engine.connects, 2);
      expect(engine.disconnects, 1);
      expect(vm.connectionVerified, true);
      await vm.disconnect();
    } finally { vm.dispose(); await engine.dispose(); }
  });
  test('cancelling while loading the catalog never starts a VPN', () async {
    final engine = AutoEngine(), catalog = Completer<PublicCatalogResult>();
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () => catalog.future, networkReader: () async => 'wifi');
    try {
      await vm.initialize(); final task = vm.autoConnect();
      await Future<void>.delayed(Duration.zero);
      await vm.cancelAutoSelection(); catalog.complete(const PublicCatalogResult([], false, 0));
      await task;
      expect(engine.connects, 0);
      expect(vm.autoSelecting, false);
    } finally { vm.dispose(); await engine.dispose(); }
  });
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
