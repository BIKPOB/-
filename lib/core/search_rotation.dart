/// Per-network scheduling history; attempts are not server failure labels.
/// Keys supplied by the caller are hashes, never profiles or credentials.
class SearchRotation {
  SearchRotation(Map<String, dynamic> storage) : _storage = storage;
  final Map<String, dynamic> _storage;
  static const retention = Duration(days: 7);

  Map<String, dynamic> _entries(String network) =>
      Map<String, dynamic>.from((_storage[network] as Map?) ?? {});

  int attemptedAt(String network, String profile, DateTime now) {
    final value = _entries(network)[profile];
    if (value is! int || value > now.millisecondsSinceEpoch ||
        now.millisecondsSinceEpoch - value >= retention.inMilliseconds) return 0;
    return value;
  }

  List<T> order<T>(List<T> ranked, String network,
      String Function(T) key, DateTime now) {
    final times = {for (final item in ranked) key(item): attemptedAt(network, key(item), now)};
    final indexed = ranked.asMap().entries.toList();
    indexed.sort((a, b) {
      final age = times[key(a.value)]!
          .compareTo(times[key(b.value)]!);
      return age != 0 ? age : a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
  }

  void mark(String network, Iterable<String> profiles, DateTime now) {
    final entries = _entries(network);
    entries.removeWhere((_, value) => value is! int ||
        value > now.millisecondsSinceEpoch ||
        now.millisecondsSinceEpoch - value >= retention.inMilliseconds);
    for (final profile in profiles) { entries[profile] = now.millisecondsSinceEpoch; }
    final sorted = entries.entries.toList()
      ..sort((a, b) => (b.value as int).compareTo(a.value as int));
    _storage.remove(network);
    _storage[network] = Map.fromEntries(sorted.take(4096));
    while (_storage.length > 8) { _storage.remove(_storage.keys.first); }
  }
}
