/// Product threshold for desktop auto-selection, not a video-service guarantee.
class SpeedPolicy {
  static const maximumTarget = 1000000;
  static const desktopMinimum = 625000;
  static const sampleMinimumBytes = 262144;
  static const sampleMaximumBytes = 4194304;
  static const sampleMinimumMs = 1500;
  static const deepFloor = 1024; // 1 KiB/s: measurable, though weak connectivity.
  static int desktopTarget(int? baselineTarget) =>
      baselineTarget != null && baselineTarget > desktopMinimum
          ? baselineTarget.clamp(1, maximumTarget)
          : desktopMinimum;
  static int networkTarget(int? baselineTarget) =>
      baselineTarget != null && baselineTarget > 0
          ? baselineTarget.clamp(1, maximumTarget)
          : desktopMinimum;
  static bool stableSamples(List<int> samples, int target) {
    if (samples.length < 3 || samples.any((s) => s < target)) return false;
    final sorted = [...samples]..sort();
    return sorted.last > 0 && sorted.first / sorted.last >= .65;
  }

  /// Deep search relaxes acceptance over its three samples: baseline,
  /// 25% (at least 16 KiB/s), then 1 KiB/s.
  static int deepRoundThreshold(int target, int round) {
    final safeTarget = target.clamp(deepFloor, maximumTarget);
    if (round <= 0) return safeTarget;
    if (round == 1) return max(deepFloor, min(safeTarget ~/ 4, 16384));
    return deepFloor;
  }

  static bool deepProgressiveSamples(List<int> samples, int target) {
    if (samples.length < 3 || samples.any((s) => s < deepFloor)) return false;
    for (var i = 0; i < 3; i++) {
      if (samples[i] < deepRoundThreshold(target, i)) return false;
    }
    final sorted = [...samples]..sort();
    // Restricted networks can fluctuate heavily; a burst followed by near-zero
    // traffic still fails the minimum 5% consistency check.
    return sorted.last > 0 && sorted.first / sorted.last >= .05;
  }

  static bool sampleComplete(int bytes, int elapsedMs) =>
      bytes >= sampleMaximumBytes ||
      (bytes >= sampleMinimumBytes && elapsedMs >= sampleMinimumMs);
}
