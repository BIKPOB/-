import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/platform/android_engine.dart';
import 'package:quiet_vpn/core/models.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/candidate-lab'), (call) async {
      if(call.method!='stop') throw StateError('Unexpected candidate operation in engine lifecycle test');
      return null;
    });
  });
  tearDown(() {messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/candidate-lab'), null);});
  testWidgets('disconnect waits for our VPN network to disappear', (tester) async {
    var reads = 0, complete = false;
    const network = MethodChannel('quietvpn/catalog-cache');
    const wg = MethodChannel('quietvpn/wg');
    const stage = MethodChannel('quietvpn/xray-state');
    messenger.setMockMethodCallHandler(network, (call) async => {'ownVpn': ++reads == 1});
    messenger.setMockMethodCallHandler(wg, (call) async => null);
    messenger.setMockMethodCallHandler(stage, (call) async => null);
    final engine = AndroidEngine();
    final stop = engine.disconnect().then((_) {complete = true;});
    await tester.pump();
    expect(complete, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    await stop;
    expect(reads, 2);
    await engine.dispose();
    messenger.setMockMethodCallHandler(network, null);
    messenger.setMockMethodCallHandler(wg, null);
    messenger.setMockMethodCallHandler(stage, null);
  });
  test('Xray receives saved bypass list and never starts when routing settings cannot be read', () async {
    Map<dynamic, dynamic>? started;
    var failRead = false;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => {for (final id in call.arguments as List) id: 1});
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/app-routing'), (call) async {
      if (failRead) throw PlatformException(code: 'storage');
      return ['com.example.bank'];
    });
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/xray-state'), (call) async {
      if (call.method == 'resolveEndpoint') return '192.0.2.1';
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_v2ray_client'), (call) async {
      if (call.method == 'requestPermission') return true;
      if (call.method == 'startV2Ray') started = call.arguments as Map;
      return null;
    });
    const server = VpnServer(id: 'test', name: 'test', country: '', countryCode: '', host: '192.0.2.1',
      port: 443, transport: 'tcp', source: 'test', protocol: 'vless',
      profile: 'vless://12345678-1234-1234-1234-123456789abc@192.0.2.1:443?security=none');
    final engine = AndroidEngine();
    try {
      await engine.connect(server, null);
      expect(started?['blocked_apps'], ['com.example.bank']);
      started = null; failRead = true;
      await expectLater(engine.connect(server, null), throwsA(isA<PlatformException>()));
      expect(started, isNull);
    } finally { await engine.dispose(); }
  });

  test('a failed proxy probe retains an explicitly unverified manual tunnel', () async {
    var stage = 'DISCONNECTED', probes = 0, stops = 0;
    for (final name in ['quietvpn/wg-events', 'flutter_v2ray_client/status']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_v2ray_client'), (call) async {
      if (call.method == 'initializeV2Ray') {
        expect(call.arguments['notificationIconResourceType'], 'drawable');
        expect(call.arguments['notificationIconResourceName'], 'ic_stat_quiet');
      }
      if (call.method == 'stopV2Ray') { stops++; stage = 'DISCONNECTED'; }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/wg'), (_) async => 'disconnected');
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/xray-state'), (call) async {
      if (call.method == 'stage') return stage;
      if (call.method == 'probe') { probes++; return {'delay': -1, 'detail': 'SOCKS TLS timeout'}; }
      return null;
    });
    final engine = AndroidEngine(), seen = <EngineEvent>[];
    final subscription = engine.events.listen(seen.add);
    try {
      await engine.initialize(); stage = 'CONNECTED'; await engine.reconcile();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.state, ConnectionState.connected);
      expect(seen.last.quality, false);
      expect(seen.last.message, contains('НЕ подтверждён'));
      expect(stops, 0);
      await engine.reconcile(); await Future<void>.delayed(Duration.zero);
      expect(probes, 1);
      await engine.disconnect(); expect(stops, 1);
    } finally { await subscription.cancel(); await engine.dispose(); }
  });
  test('quick Xray check confirms HTTPS before a separate speed download', () async {
    var stage = 'CONNECTED', fast = 0, normal = 0;
    final speed = Completer<Map<String, dynamic>>();
    final events = <EngineEvent>[];
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_v2ray_client'), (call) async {
      if (call.method == 'stopV2Ray') stage = 'DISCONNECTED';
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/wg'), (call) async => 'disconnected');
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/catalog-cache'),
      (_) async => {'ownVpn': false});
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/xray-state'), (call) async {
      if (call.method == 'stage') return stage;
      if (call.method == 'probe') {
        if (call.arguments['quick'] == true) {
          fast++;
          return {'delay': 125, 'httpsVerified': true, 'quality': false,
            'detail': 'HTTPS подтверждён'};
        }
        normal++;
        return speed.future;
      }
      return null;
    });
    final engine = AndroidEngine();
    final sub = engine.events.listen(events.add);
    try {
      engine.setQuickProbe(true);
      await engine.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fast, 1);
      expect(normal, 1);
      final first = events.lastWhere((e) => e.httpsVerified);
      expect(first.state, ConnectionState.connected);
      expect(first.bytesPerSecond, isNull);
      expect(first.quality, isFalse);
      speed.complete({'delay': 8000, 'bytesPerSecond': 180000,
        'quality': true, 'detail': 'speed complete'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events.last.bytesPerSecond, 180000);
      expect(events.last.httpsVerified, isTrue);
      await engine.disconnect();
    } finally {
      if (!speed.isCompleted) speed.complete({'delay': -1});
      await sub.cancel(); await engine.dispose();
      for (final name in ['flutter_v2ray_client','quietvpn/wg',
        'quietvpn/catalog-cache','quietvpn/xray-state']) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    }
  });
  test('failed native stop is retryable without restarting app', () async {
    var stage = 'CONNECTED', stopAttempts = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_v2ray_client'), (call) async {
      if (call.method == 'stopV2Ray') {
        stopAttempts++;
        if (stopAttempts == 1) throw PlatformException(code: 'stop-failed');
        stage = 'DISCONNECTED';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/wg'), (_) async => 'disconnected');
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/catalog-cache'),
      (_) async => {'ownVpn': false});
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/xray-state'), (call) async {
      if (call.method == 'stage') return stage;
      if (call.method == 'probe') return {'delay': -1};
      return null;
    });
    final engine = AndroidEngine();
    try {
      await engine.initialize();
      await expectLater(engine.disconnect(), throwsA(isA<PlatformException>()));
      await engine.disconnect();
      expect(stopAttempts, 2);
    } finally {
      await engine.dispose();
      for (final name in ['flutter_v2ray_client','quietvpn/wg',
        'quietvpn/catalog-cache','quietvpn/xray-state']) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    }
  });
  test('WireGuard session reconciles and native stop failure propagates', () async {
    var wg = 'connecting';
    for (final name in ['quietvpn/wg-events','flutter_v2ray_client/status','flutter_v2ray_client']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/xray-state'), (_) async => 'DISCONNECTED');
    messenger.setMockMethodCallHandler(const MethodChannel('quietvpn/wg'), (call) async {
      if(call.method=='stage')return wg;
      if(call.method=='stop')throw PlatformException(code:'stop',message:'not stopped');
      return null;
    });
    final engine=AndroidEngine(), seen=<ConnectionState>[];
    final subscription=engine.events.listen((event)=>seen.add(event.state));
    try {
      await engine.initialize(); wg='connected'; await engine.reconcile();
      await Future<void>.delayed(Duration.zero);
      expect(seen,[ConnectionState.connecting,ConnectionState.connected]);
      await expectLater(engine.disconnect(),throwsA(isA<PlatformException>()));
    }finally {await subscription.cancel();await engine.dispose();}
  });
}
