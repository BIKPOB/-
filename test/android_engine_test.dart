import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/platform/android_engine.dart';
import 'package:quiet_vpn/core/models.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test('a failed proxy probe retains an explicitly unverified manual tunnel', () async {
    var stage = 'DISCONNECTED', probes = 0, stops = 0;
    for (final name in ['quietvpn/wg-events', 'flutter_v2ray_client/status']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_v2ray_client'), (call) async {
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
