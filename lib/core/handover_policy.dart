/// Hysteresis and bounded traffic/attempt budgets, independent of UI timers.
class HandoverPolicy {
  int _bad = 0;
  DateTime? _badSince, _lastSwitch, _hour;
  int _bytes = 0;
  final _switches = <DateTime>[];
  final _failed = <String, DateTime>{};
  void resetEvidence() { _bad=0; _badSince=null; }
  void observe(int? speed, int target, DateTime now) {
    if (speed != null && speed >= target * .6) { _bad = 0; _badSince = null; return; }
    _bad++; _badSince ??= now;
  }
  bool degraded(DateTime now) => _bad >= 3 && _badSince != null &&
      now.difference(_badSince!) >= const Duration(minutes: 2);
  bool eligible(String profile, DateTime now) => !_failed.containsKey(profile) ||
      now.difference(_failed[profile]!) >= const Duration(minutes: 30);
  bool reserveBytes(int bytes, bool metered, DateTime now) {
    if (_hour == null || now.difference(_hour!) >= const Duration(hours: 1)) {
      _hour = now; _bytes = 0;
    }
    final limit = (metered ? 24 : 96) * 1048576;
    if (_bytes + bytes > limit) return false;
    _bytes += bytes; return true;
  }
  bool canSwitch({required String profile, required int speed, required int current,
      required int target, required DateTime measuredAt, required DateTime now}) {
    _switches.removeWhere((t) => now.difference(t) >= const Duration(hours: 1));
    return degraded(now) && eligible(profile, now) && _switches.length < 2 &&
      (_lastSwitch == null || now.difference(_lastSwitch!) >= const Duration(minutes: 10)) &&
      !now.isBefore(measuredAt) && now.difference(measuredAt) < const Duration(minutes: 2) &&
      speed >= target && speed >= current * 1.5;
  }
  void beginSwitch(DateTime now) {
    _lastSwitch = now; _switches.add(now); _bad = 0; _badSince = null;
  }
  void failed(String profile, DateTime now) { _failed[profile] = now; }
}
