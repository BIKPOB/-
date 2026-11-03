import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/presentation_state.dart';

void main() {
  test('session duration includes time with no foreground rendering ticks', () {
    var now = DateTime.utc(2026, 10, 30);
    final clock = SessionClock(now: () => now);
    clock.connected();
    now = now.add(const Duration(minutes: 7, seconds: 19));
    clock.connected(); // Reconciliation confirms the same running tunnel.
    expect(clock.elapsed, const Duration(minutes: 7, seconds: 19));
    clock.stopped();
    expect(clock.elapsed, Duration.zero);
    clock.connected();
    now = now.add(const Duration(seconds: 3));
    expect(clock.elapsed.inSeconds, 3);
  });
  test('quick divisions count seconds and never exceed deadline', () {
    final start = DateTime.utc(2026, 10, 30);
    final progress = SearchProgress()..start(false, start);
    expect(progress.steps(start.add(const Duration(milliseconds: 1900))), 1);
    expect(progress.fraction(start.add(const Duration(seconds: 10))), 10 / 15);
    expect(progress.steps(start.add(const Duration(seconds: 40))), 15);
  });
  test(
    'deep preparation is indeterminate and counts only finished queue items',
    () {
      final now = DateTime.utc(2026, 10, 30);
      final progress = SearchProgress()..start(true, now);
      expect(progress.fraction(now), isNull);
      progress.total = 8;
      expect(progress.fraction(now.add(const Duration(minutes: 5))), 0);
      progress.completed = 3;
      expect(progress.fraction(now), 3 / 8);
      progress.beginRound(2);
      expect(progress.completed, 0);
      expect(progress.fraction(now), isNull);
      expect(progress.label(now), contains('2/4'));
    },
  );
}
