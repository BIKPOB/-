import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:quiet_vpn/ui/home_page.dart';
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
  String? selector;
  @override Future<List<VpnServer>> load() async => [server];
  @override Future<String?> loadSelector() async => selector;
  @override Future<void> saveSelector(String value) async { selector = value; }
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
class NetworkMetadataEngine extends ControlledEngine {
  bool tunnel = false;
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    connects++; tunnel = true;
    controller.add(EngineEvent(ConnectionState.connected, 'probe result', connects > 1));
  }
  @override Future<void> disconnect() async { disconnects++; tunnel = false; }
}
class MeasuredEngine extends ControlledEngine {
  final chosen = <String>[];
  int currentSpeed = 0;
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    connects++; chosen.add(server.host);
    currentSpeed = server.host == '9.9.9.9' ? 900000 : 200000;
    controller.add(EngineEvent(ConnectionState.connected, 'measured', true, currentSpeed));
  }
}
class RetryEngine extends ControlledEngine {
  final chosen = <String>[];
  @override Future<void> connect(VpnServer server, Credentials? credentials) async {
    connects++; chosen.add(server.host);
    controller.add(EngineEvent(ConnectionState.connected, 'measured',
      server.host == '9.9.9.9', server.host == '9.9.9.9' ? 200000 : null));
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('quick selection keeps first measured success without repeated probes or reconnect', () async {
    final engine = MeasuredEngine();
    final other = VpnServer.fromJson({...server.toJson(), 'id': 'other', 'host': '9.9.9.9',
      'profile': server.profile.replaceAll('8.8.8.8', '9.9.9.9')});
    var repeatProbes = 0;
    const channel = MethodChannel('quietvpn/xray-state');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) async { repeatProbes++; return null; });
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () async => PublicCatalogResult([other], false, 0), networkReader: () async => 'wifi',
      autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize(); await vm.autoConnect();
      expect(engine.connects, 1); expect(engine.disconnects, 0);
      expect(repeatProbes, 0); expect(vm.connectionVerified, true);
      expect(vm.learningSamples, 1);
      await vm.disconnect();
    } finally {
      vm.dispose(); await engine.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('next quick search tries the saved verified profile before the failed one', () async {
    final profiles = MemoryProfiles();
    final other = VpnServer.fromJson({...server.toJson(), 'id': 'other', 'host': '9.9.9.9',
      'profile': server.profile.replaceAll('8.8.8.8', '9.9.9.9')});
    for (var round = 0; round < 2; round++) {
      final engine = RetryEngine();
      final vm = VpnViewModel(engine, profiles,
        ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
        catalogLoader: () async => PublicCatalogResult([other], false, 0), networkReader: () async => 'wifi',
        autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
      try {
        await vm.initialize(); await vm.autoConnect();
        expect(vm.connectionVerified, true);
        expect(engine.chosen, round == 0 ? ['8.8.8.8', '9.9.9.9'] : ['9.9.9.9']);
        await vm.disconnect();
      } finally { vm.dispose(); await engine.dispose(); }
    }
  });
  testWidgets('notification shade preserves search; actually hiding the app cancels it', (tester) async {
    final engine = AutoEngine(), catalog = Completer<PublicCatalogResult>();
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () => catalog.future, networkReader: () async => 'wifi');
    await tester.pumpWidget(MaterialApp(home: HomePage(vm)));
    await tester.pump();
    expect(vm.ready, true);
    final search = vm.autoConnect(deep: true);
    await tester.pump();
    expect(vm.autoSelecting, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(vm.autoStatus, isNot('Подбор остановлен'));
    expect(vm.autoSelecting, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(vm.autoStatus, isNot('Подбор остановлен'));
    expect(engine.disconnects, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(vm.autoStatus, 'Подбор остановлен: приложение ушло в фон');
    catalog.complete(const PublicCatalogResult([], false, 0));
    await tester.pump(); await search;
    expect(engine.connects, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await engine.dispose();
  });

  test('deep selection compares successful candidates and reconnects the faster one', () async {
    final engine = MeasuredEngine();
    const channel = MethodChannel('quietvpn/xray-state');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) async => {'delay': 100, 'quality': true, 'bytesPerSecond': engine.currentSpeed});
    final other = VpnServer.fromJson({...server.toJson(), 'id': 'fast', 'host': '9.9.9.9',
      'profile': server.profile.replaceAll('8.8.8.8', '9.9.9.9')});
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () async => PublicCatalogResult([other], false, 0), networkReader: () async => 'wifi',
      autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize(); await vm.autoConnect(deep: true);
      expect(engine.connects, 3);
      expect(engine.chosen.last, '9.9.9.9');
      expect(vm.learningSamples, 2);
      expect(vm.learningJournal.length, 2);
      expect(vm.connectionVerified, true);
      await vm.disconnect();
    } finally {
      vm.dispose(); await engine.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('cancellation during repeated measurement neither trains nor reconnects', () async {
    final engine = MeasuredEngine(), probe = Completer<Map<String, dynamic>>();
    final probing = Completer<void>();
    const channel = MethodChannel('quietvpn/xray-state');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) { probing.complete(); return probe.future; });
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () async => const PublicCatalogResult([], false, 0), networkReader: () async => 'wifi',
      autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize(); final task = vm.autoConnect(deep: true);
      await probing.future; await vm.cancelAutoSelection();
      probe.complete({'delay': 100, 'quality': true, 'bytesPerSecond': 900000});
      await task;
      expect(vm.learningSamples, 0);
      expect(vm.learningJournal, isEmpty);
      expect(engine.connects, 1);
      expect(vm.canDisconnect, false);
    } finally {
      vm.dispose(); await engine.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('VPN metadata change after a failed candidate does not cancel the next attempt', () async {
    final engine = NetworkMetadataEngine();
    final other = VpnServer.fromJson({...server.toJson(), 'id': 'second', 'host': '9.9.9.9',
      'profile': server.profile.replaceAll('8.8.8.8', '9.9.9.9')});
    final vm = VpnViewModel(engine, MemoryProfiles(),
      ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)),
      catalogLoader: () async => PublicCatalogResult([other], false, 0),
      networkReader: () async => engine.tunnel && engine.connects == 1 ? 'other' : 'wifi',
      autoMonitor: ServerMonitor(probe: (_) async => const HealthResult(Reachability.reachable, 1)));
    try {
      await vm.initialize(); vm.filterProtocol('wireguard'); await vm.autoConnect();
      expect(engine.connects, 2);
      expect(vm.connectionVerified, true);
      expect(vm.protocolFilter, isNull);
      expect(vm.autoPlan, contains('vless'));
      await vm.disconnect();
    } finally { vm.dispose(); await engine.dispose(); }
  });
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

