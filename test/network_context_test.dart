import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_context.dart';
import 'package:quiet_vpn/core/adaptive_selector.dart';

void main() {
  test('signal fluctuation keeps session, changing Wi-Fi cancels session', () {
    const a = NetworkContext(type: 'wifi', session: '1', signal: -60);
    expect(a.sameConnection(const NetworkContext(type: 'wifi', session: '1', signal: -85)), isTrue);
    expect(a.sameConnection(const NetworkContext(type: 'wifi', session: '2')), isFalse);
  });
  test('missing and weak signal are distinct and features remain bounded', () {
    const missing = NetworkContext();
    const weak = NetworkContext(signal: -120, downKbps: 10000000, upKbps: -1);
    expect(missing.features[1], 0);
    expect(weak.features[1], 1);
    expect(weak.features.every((v) => v.isFinite && v >= -1 && v <= 1), isTrue);
  });
  test('old model migration retains predictions with neutral context weights', () {
    final old = {
      'hidden': List.generate(6, (_) => List.filled(9, .1)),
      'output': List.filled(7, .2), 'history': <String, dynamic>{}, 'samples': 3,
    };
    final migrated = AdaptiveSelector.decode(jsonEncode(old));
    expect(migrated.samples, 3);
    expect(migrated.hidden.first.length, 16);
    final a = migrated.predict(List.filled(15, 0));
    final b = migrated.predict([...List.filled(8, 0.0), ...List.filled(7, 1.0)]);
    expect(a, b);
    expect(AdaptiveSelector.decode(migrated.encode()).predict(List.filled(15, 0)), a);
  });
}
