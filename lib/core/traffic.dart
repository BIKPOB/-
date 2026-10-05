class TrafficCounters {
  const TrafficCounters(this.received, this.sent);
  final int received, sent;
}

abstract interface class TrafficSource {
  Future<TrafficCounters?> readTraffic();
}

class TrafficMeter {
  TrafficCounters? _last;
  Duration? _time;
  double? download, upload;
  void reset() { _last = null; _time = null; download = null; upload = null; }
  void sample(TrafficCounters counters, Duration time) {
    final previous = _last;
    final elapsed = _time == null ? 0 : (time - _time!).inMicroseconds;
    download = null; upload = null;
    if (previous != null && elapsed > 0 && counters.received >= previous.received && counters.sent >= previous.sent) {
      download = (counters.received - previous.received) * 1000000 / elapsed;
      upload = (counters.sent - previous.sent) * 1000000 / elapsed;
    }
    _last = counters; _time = time;
  }
}

String formatTrafficRate(double? bytes) {
  if (bytes == null) return '—';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} МиБ/с';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} КиБ/с';
  return '${bytes.toStringAsFixed(0)} Б/с';
}
