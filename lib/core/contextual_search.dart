import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'network_context.dart';

/// A bounded, local, non-stationary Bernoulli source estimator.
///
/// The optimistic term is UCB-inspired, NOT a calibrated probability or a
/// mathematical guarantee for censored VPN observations. Only real TUN HTTPS
/// successes count as successes. An attempted but unconfirmed VPN contributes
/// 0.25 of a failure; a TCP timeout or proxy-only test contributes nothing.
class SourceReliability {
  final Map<String, List<double>> _stats = {};
  static const halfLife = Duration(hours: 48);
  static const maxSources = 192;
  int get learnedSources => _stats.length;
  String _key(VpnServer server, NetworkContext network) {
    var origin = server.source.trim().toLowerCase();
    for (final prefix in ['ии-подбор · ', 'публичный · ', 'резерв · ']) {
      if (origin.startsWith(prefix)) {
        origin = origin.substring(prefix.length);
        break;
      }
    }
    final scope = network.type == 'mobile' ? 'mobile'
        : network.type == 'wifi' ? 'wifi'
        : network.type == 'ethernet' ? 'ethernet' : 'other';
    return sha256.convert(utf8.encode(
      '$origin|${server.protocol}|$scope')).toString();
  }
  List<double> _at(String id, DateTime now) {
    final old = _stats[id];
    if (old == null) { return [0, 0, now.millisecondsSinceEpoch.toDouble()]; }
    final delta = now.millisecondsSinceEpoch - old[2].round();
    if (delta < 0) { return [0, 0, now.millisecondsSinceEpoch.toDouble()]; }
    final decay = pow(.5, delta / halfLife.inMilliseconds).toDouble();
    return [old[0] * decay, old[1] * decay,
      now.millisecondsSinceEpoch.toDouble()];
  }
  void observe(VpnServer server, NetworkContext network,
      {required bool verifiedVpn, bool attemptedButUnconfirmed = false,
      DateTime? now}) {
    if (network.ambiguous || network.type == 'offline' ||
        (!verifiedVpn && !attemptedButUnconfirmed)) { return; }
    final clock = (now ?? DateTime.now()).toUtc();
    final id = _key(server, network);
    final data = _at(id, clock);
    if (verifiedVpn) {
      data[0] += 1;
    } else {
      data[1] += .25; // A timeout may be network-dependent, never a hard ban.
    }
    _stats.remove(id);
    _stats[id] = data;
    while (_stats.length > maxSources) { _stats.remove(_stats.keys.first); }
  }
  ({double mean, double optimistic, double exposure}) estimate(
      VpnServer server, NetworkContext context, {DateTime? now}) {
    if (context.ambiguous) { return (mean:.5, optimistic:.5, exposure:0); }
    final sample = _at(_key(server, context), (now ?? DateTime.now()).toUtc());
    final observed = sample[0] + sample[1];
    // Beta(2,2) smoothing avoids treating one success as certainty.
    final mean = (2 + sample[0]) / (4 + observed);
    // Deliberately bounded optimism to keep untried sources represented.
    final bonus = min(.12, .16 / sqrt(1 + observed));
    return (mean:mean, optimistic:min(1.0, mean + bonus), exposure:observed);
  }
  Map<String, dynamic> encode() => {
    'version':1,
    'stats': {for (final entry in _stats.entries) entry.key:entry.value},
  };
  static SourceReliability decode(dynamic data) {
    final result = SourceReliability();
    if (data is! Map || data['version'] != 1 || data['stats'] is! Map) { return result; }
    final input = data['stats'] as Map;
    if (input.length > maxSources) { return result; }
    for (final entry in input.entries) {
      if (entry.key is! String || (entry.key as String).length != 64 ||
          entry.value is! List || (entry.value as List).length != 3) { continue; }
      try {
        final numbers = (entry.value as List).map((e) => (e as num).toDouble()).toList();
        if (numbers.any((n) => !n.isFinite) || numbers[0] < 0 || numbers[1] < 0 ||
            numbers[0] > 100000 || numbers[1] > 100000 || numbers[2] < 0) { continue; }
        result._stats[entry.key as String] = numbers;
      } catch (_) { /* Ignore only the damaged source entry. */ }
    }
    return result;
  }
}

/// Contextual ranking, constrained by a fixed 15-second search budget.
/// Old connection/validation code is unchanged; this only chooses order.
class ContextualSearchPlanner {
  static List<VpnServer> quick({
    required List<VpnServer> baseline,
    required List<VpnServer> historical,
    required double Function(VpnServer) desirability,
    required double Function(VpnServer) sourceExposure,
    int limit = 6,
  }) {
    if (limit <= 0) { return []; }
    final result = <VpnServer>[], used = <String>{};
    String key(VpnServer s) => '${s.protocol}|${s.protocol == 'wireguard'
        ? s.profile.trim() : s.profile.split('#').first}';
    void add(VpnServer s) { if (result.length < limit && used.add(key(s))) { result.add(s); } }
    // At most two proven profiles; the remaining candidates still explore.
    for (final s in historical.take(2)) { add(s); }
    // Read changing/decaying evidence once per profile. Re-evaluating it inside
    // a comparator can make the same pair change order during one sort.
    final scores = <String, double>{};
    final exposures = <String, double>{};
    for (final server in baseline) {
      scores.putIfAbsent(key(server), () => desirability(server));
      exposures.putIfAbsent(key(server), () => sourceExposure(server));
    }
    final candidates = baseline.asMap().entries.toList();
    candidates.sort((a, b) {
      final delta = scores[key(b.value)]!.compareTo(scores[key(a.value)]!);
      return delta != 0 ? delta : a.key.compareTo(b.key);
    });
    // Hold one position for a less-tested source if one exists.
    final lastSlot = limit > 2 ? limit - 1 : limit;
    final counts = <String, int>{};
    for (final s in result) { counts[s.source] = (counts[s.source] ?? 0) + 1; }
    for (final entry in candidates) {
      if (result.length >= lastSlot) break;
      final s = entry.value;
      if ((counts[s.source] ?? 0) >= 2) { continue; }
      final before = result.length;
      add(s);
      if (result.length > before) counts[s.source] = (counts[s.source] ?? 0) + 1;
    }
    // Choose exploration by minimum evidence, then by original rank.
    if (result.length < limit) {
      final remaining = baseline.asMap().entries.where((e) => !used.contains(key(e.value))).toList();
      remaining.sort((a, b) {
        final c = exposures[key(a.value)]!.compareTo(exposures[key(b.value)]!);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
      if (remaining.isNotEmpty) add(remaining.first.value);
    }
    // Relax the per-source cap when there are few usable sources.
    for (final entry in candidates) {
      if (result.length >= limit) { break; }
      add(entry.value);
    }
    return result;
  }
}
