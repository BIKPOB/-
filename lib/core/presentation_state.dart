/// UI clocks do not depend on rendering ticks or foreground lifecycle.
class SessionClock {
  SessionClock({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  DateTime? startedAt;
  void connected() => startedAt ??= _now();
  void stopped() => startedAt = null;
  Duration get elapsed {
    final duration = startedAt == null
        ? Duration.zero
        : _now().difference(startedAt!);
    return duration.isNegative ? Duration.zero : duration;
  }
}

class SearchProgress {
  bool deep = false;
  DateTime? startedAt;
  int round = 0, total = 0, completed = 0;
  void start(bool isDeep, DateTime now) {
    deep = isDeep;
    startedAt = now;
    beginRound(1);
  }

  void beginRound(int value) {
    round = value;
    total = 0;
    completed = 0;
  }

  int steps(DateTime now) => deep
      ? completed
      : (startedAt == null
            ? 0
            : now.difference(startedAt!).inSeconds.clamp(0, 15));
  int get divisions => deep ? total : 15;
  double? fraction(DateTime now) =>
      divisions == 0 ? null : steps(now) / divisions;
  String label(DateTime now) => deep
      ? (total == 0
            ? 'Раунд $round/4 · подготовка очереди'
            : 'Раунд $round/4 · проверено $completed/$total')
      : '${steps(now)}/15 сек.';
}

class ConnectionMessage {
  const ConnectionMessage(this.id, this.text, {this.error = false});
  final int id;
  final String text;
  final bool error;
}
