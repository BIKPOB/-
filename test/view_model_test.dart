import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/data/catalog_repository.dart';
import 'package:quiet_vpn/data/profile_store.dart';
import 'package:quiet_vpn/platform/vpn_engine.dart';
import 'package:quiet_vpn/viewmodels/vpn_view_model.dart';

const server = VpnServer(id: 'fixture', name: 'fixture', country: 'Test', countryCode: 'US',
  host: '8.8.8.8', port: 443, transport: 'tcp', source: 'test',
  profile: 'client\ndev tun\nproto tcp\nremote 8.8.8.8 443\n<ca>\nNOT A REAL CERT\n</ca>\n');

class MemoryProfiles extends ProfileStore {
  @override Future<List<VpnServer>> load() async => [];
  @override Future<Credentials?> credentials(String id) async => null;
}
class MemoryCatalog extends CatalogRepository {
  MemoryCatalog() : super(File('unused-test-cache'));
  @override Future<CatalogResult> load({bool force = false}) async => CatalogResult([server], DateTime.now());
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
  test('clearing catalog cache preserves an active tunnel and pauses refresh', () async {
    final engine = ControlledEngine();
    final vm = VpnViewModel(engine, MemoryCatalog(), MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize();
      final attempt = vm.connect(null);
      await engine.started.future;
      engine.release.complete(); await attempt;
      await vm.clearCatalogCache();
      expect(vm.servers, isEmpty);
      expect(vm.autoRefresh, isFalse);
      expect(vm.activeServer?.id, server.id);
      expect(vm.canDisconnect, isTrue);
      expect(engine.disconnects, 0);
      await vm.refresh(force: true);
      expect(vm.autoRefresh, isTrue);
      expect(vm.servers, isNotEmpty);
      await vm.disconnect();
    } finally { vm.dispose(); await engine.dispose(); }
  });
  test('cache deletion is scoped to catalog and temporary cache files', () async {
    final dir = await Directory.systemTemp.createTemp('quiet-vpn-cache-test-');
    try {
      final cache = File('${dir.path}/catalog.json');
      final retained = File('${dir.path}/keep.txt');
      await cache.writeAsString('cached');
      await File('${cache.path}.tmp').writeAsString('partial');
      await retained.writeAsString('retain');
      final catalog = CatalogRepository(cache);
      await catalog.clearCache();
      expect(await cache.exists(), isFalse);
      expect(await File('${cache.path}.tmp').exists(), isFalse);
      expect(await retained.readAsString(), 'retain');
    } finally { await dir.delete(recursive: true); }
  });
  test('double connect is dropped while the native start is in progress', () async {
    final engine = ControlledEngine();
    final vm = VpnViewModel(engine, MemoryCatalog(), MemoryProfiles(),
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
    final vm = VpnViewModel(engine, MemoryCatalog(), MemoryProfiles(),
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
