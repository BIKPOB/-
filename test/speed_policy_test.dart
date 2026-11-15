import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/speed_policy.dart';

void main() {
  test('fresh LTE baseline target is not raised above the displayed target', () {
    expect(SpeedPolicy.networkTarget(412500), 412500);
    expect(SpeedPolicy.networkTarget(2272500), 1000000);
    expect(SpeedPolicy.networkTarget(null), 625000);
  });
  test('desktop target has a minimum and scales with a faster baseline', () {
    expect(SpeedPolicy.desktopTarget(null), 625000);
    expect(SpeedPolicy.desktopTarget(100000), 625000);
    expect(SpeedPolicy.desktopTarget(3000000), 1000000);
  });
  test('stable speed requires three samples above target without sharp drops', () {
    expect(SpeedPolicy.stableSamples([1000000, 900000, 850000], 625000), true);
    expect(SpeedPolicy.stableSamples([4000000, 1000000, 900000], 625000), false);
    expect(SpeedPolicy.stableSamples([1000000, 900000, 500000], 625000), false);
    expect(SpeedPolicy.stableSamples([1000000, 900000], 625000), false);
  });
  test('deep search progressively lowers speed threshold to 1 KiB/s', () {
    expect(SpeedPolicy.deepRoundThreshold(625000, 0), 625000);
    expect(SpeedPolicy.deepRoundThreshold(625000, 1), 16384);
    expect(SpeedPolicy.deepRoundThreshold(625000, 2), 1024);
    expect(SpeedPolicy.deepProgressiveSamples([700000, 20000, 1024], 625000), true);
    expect(SpeedPolicy.deepProgressiveSamples([700000, 20000, 0], 625000), false);
    expect(SpeedPolicy.deepProgressiveSamples([700000, 20000, 900], 625000), false);
  });
  test('a short 256 KiB burst cannot finish the measurement', () {
    expect(SpeedPolicy.sampleComplete(262144, 20), false);
    expect(SpeedPolicy.sampleComplete(262144, 1500), true);
    expect(SpeedPolicy.sampleComplete(1000, 1500), false);
    expect(SpeedPolicy.sampleComplete(4194304, 100), true);
  });
}
