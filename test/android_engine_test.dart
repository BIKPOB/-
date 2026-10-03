import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/platform/android_engine.dart';
import 'package:quiet_vpn/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const control = MethodChannel('quietvpn/openvpn');
  const events = MethodChannel('quietvpn/openvpn-events');
  test('native OpenVPN stages survive reconciliation and stop is acknowledged', () async {
    var stage = 'connecting';
    final calls = <String>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call.method);
      if (call.method == 'stage') return stage;
      if (call.method == 'stop') stage = 'disconnected';
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    final engine = OpenVpnAndroidEngine();
    final seen = <ConnectionState>[];
    final subscription = engine.events.listen((event) => seen.add(event.state));
    try {
      await engine.initialize();
      stage = 'connected'; await engine.reconcile();
      await engine.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(seen, [ConnectionState.connecting, ConnectionState.connected, ConnectionState.disconnected]);
      expect(calls, contains('stop'));
    } finally {
      await subscription.cancel(); await engine.dispose();
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
  test('native stop failure is propagated instead of reporting disconnected', () async {
    messenger.setMockMethodCallHandler(control, (call) async {
      throw PlatformException(code: 'stop', message: 'service unavailable');
    });
    final engine = OpenVpnAndroidEngine();
    try { await expectLater(engine.disconnect(), throwsA(isA<PlatformException>())); }
    finally { await engine.dispose(); messenger.setMockMethodCallHandler(control, null); }
  });
}
