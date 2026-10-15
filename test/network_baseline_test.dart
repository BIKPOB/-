import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_baseline.dart';
import 'package:quiet_vpn/core/network_context.dart';

void main() {
  test('baseline is scoped to network session and expires without becoming a speed claim', () {
    final now = DateTime(2026, 10, 15);
    final sample = NetworkBaseline('wifi-a', 'wifi', now, 1000000, 50);
    expect(sample.target, 600000);
    expect(sample.fresh(const NetworkContext(type: 'wifi', session: 'wifi-a'), now), true);
    expect(sample.fresh(const NetworkContext(type: 'wifi', session: 'wifi-b'), now), false);
    expect(sample.fresh(const NetworkContext(type: 'mobile', session: 'wifi-a'), now), false);
    expect(sample.fresh(const NetworkContext(type: 'wifi', session: 'wifi-a', ambiguous: true), now), false);
    expect(sample.fresh(const NetworkContext(type: 'wifi', session: 'wifi-a'), now.add(const Duration(hours: 2))), false);
    expect(sample.fresh(const NetworkContext(type: 'wifi', session: 'wifi-a'), now.subtract(const Duration(seconds: 1))), false);
    final saved = NetworkBaseline.fromJson(sample.toJson());
    expect(saved.bytesPerSecond, sample.bytesPerSecond);
    expect(saved.session, sample.session);
  });
}
