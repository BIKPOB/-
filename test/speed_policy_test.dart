import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/speed_policy.dart';

void main() {
  test('desktop target has a minimum and scales with a faster baseline', () {
    expect(SpeedPolicy.desktopTarget(null), 625000);
    expect(SpeedPolicy.desktopTarget(100000), 625000);
    expect(SpeedPolicy.desktopTarget(3000000), 3000000);
  });
  test('a short 256 KiB burst cannot finish the measurement', () {
    expect(SpeedPolicy.sampleComplete(262144, 20), false);
    expect(SpeedPolicy.sampleComplete(262144, 1500), true);
    expect(SpeedPolicy.sampleComplete(1000, 1500), false);
    expect(SpeedPolicy.sampleComplete(4194304, 100), true);
  });
}
