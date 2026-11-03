import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/traffic.dart';

void main() {
  test('traffic uses elapsed time and rebaselines reset counters', () {
    final meter = TrafficMeter();
    meter.sample(const TrafficCounters(100, 200), Duration.zero);
    expect(meter.download, isNull);
    meter.sample(const TrafficCounters(2100, 1200), const Duration(seconds: 2));
    expect(meter.download, 1000); expect(meter.upload, 500);
    meter.sample(const TrafficCounters(1, 2), const Duration(seconds: 3));
    expect(meter.download, isNull);
    meter.sample(const TrafficCounters(1, 2), const Duration(seconds: 4));
    expect(meter.download, 0);
    meter.reset(); expect(meter.upload, isNull);
  });
}
