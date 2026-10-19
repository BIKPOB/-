/// Product threshold for desktop auto-selection, not a video-service guarantee.
class SpeedPolicy {
  static const desktopMinimum = 625000; // 5 decimal Mbit/s.
  static const sampleMinimumBytes = 262144;
  static const sampleMaximumBytes = 4194304;
  static const sampleMinimumMs = 1500;
  static int desktopTarget(int? baselineTarget) =>
    baselineTarget != null && baselineTarget > desktopMinimum ? baselineTarget : desktopMinimum;
  static bool stableSamples(List<int> samples, int target) {
    if (samples.length < 3 || samples.any((s) => s < target)) return false;
    final sorted = [...samples]..sort();
    return sorted.last > 0 && sorted.first / sorted.last >= .65;
  }
  static bool sampleComplete(int bytes, int elapsedMs) =>
    bytes >= sampleMaximumBytes || (bytes >= sampleMinimumBytes && elapsedMs >= sampleMinimumMs);
}
