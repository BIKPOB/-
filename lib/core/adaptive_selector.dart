import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'network_context.dart';

/// Small on-device neural classifier: 18 inputs, 6 tanh units, sigmoid output.
/// Starts untrained; learns only from verified connections, not ICMP responses.
class AdaptiveSelector {
  /// Input is already ranked. Round-robin keeps one protocol from using all slots.
  static List<VpnServer> shortlist(List<VpnServer> ranked, {int limit = 6}) {
    final groups = <String, List<VpnServer>>{};
    for (final server in ranked) {
      groups.putIfAbsent(server.protocol, () => []).add(server);
    }
    final result = <VpnServer>[];
    for (var round = 0; result.length < limit; round++) {
      var added = false;
      for (final group in groups.values) {
        if (round < group.length && result.length < limit) {
          result.add(group[round]); added = true;
        }
      }
      if (!added) break;
    }
    return result;
  }
  AdaptiveSelector() {
    final random = Random(754);
    hidden = List.generate(6, (_) => List.generate(19, (_) => (random.nextDouble() - .5) * .2));
  }
  late List<List<double>> hidden;
  List<double> output = List.filled(7, 0);
  final history = <String, List<int>>{};
  int samples = 0;
  final journal = <Map<String, dynamic>>[];
  void record(VpnServer server, NetworkContext context, String outcome, {int? speed}) {
    journal.add({'time': DateTime.now().toUtc().toIso8601String(),
      'profile': key(server, context.environmentKey), 'network': context.type,
      'protocol': server.protocol, 'outcome': outcome, 'bytesPerSecond': speed});
    if (journal.length > 200) journal.removeAt(0);
  }
  String key(VpnServer s, String network) => sha256.convert(utf8.encode('$network|${s.protocol}|${s.profile}')).toString();
  List<double> features(VpnServer s, String network, int? latency, {NetworkContext? context}) {
    final h = history[key(s, context?.environmentKey ?? network)] ?? [0, 0];
    return [s.protocol == 'wireguard' ? 1 : 0, s.protocol == 'vless' ? 1 : 0,
      s.protocol == 'shadowsocks' ? 1 : 0, network == 'wifi' ? 1 : 0,
      network == 'mobile' ? 1 : 0, latency == null ? 0 : 1 / (1 + latency / 200),
      (h[0] + 1) / (h[1] + 2), min(h[1], 10) / 10, ...(context ?? NetworkContext(type: network)).features];
  }
  List<double> _activation(List<double> x) => hidden.map((w) {
    var z = w.last;
    for (var i = 0; i < 18; i++) { z += w[i] * x[i]; }
    final e = exp(2 * z.clamp(-15, 15));
    return (e - 1) / (e + 1);
  }).toList();
  double predict(List<double> x) {
    final h = _activation(x);
    var z = output.last;
    for (var j = 0; j < 6; j++) { z += output[j] * h[j]; }
    return 1 / (1 + exp(-z.clamp(-30, 30)));
  }
  double score(VpnServer s, String network, int? latency, {NetworkContext? context}) {
    final x = features(s, network, latency, context: context);
    return .65 * predict(x) + .25 * x[6] + .1 * x[5];
  }
  void observe(VpnServer s, String network, int? latency, {required bool success, NetworkContext? context, double? reward}) {
    final x = features(s, network, latency, context: context);
    for (var step = 0; step < 4; step++) {
      final h = _activation(x), old = List<double>.from(output);
      final error = predict(x) - (reward ?? (success ? 1 : 0)).clamp(0, 1);
      for (var j = 0; j < 6; j++) {
        final delta = error * old[j] * (1 - h[j] * h[j]);
        for (var i = 0; i < 18; i++) { hidden[j][i] -= .08 * delta * x[i]; }
        hidden[j][18] -= .08 * delta;
        output[j] -= .08 * error * h[j];
      }
      output[6] -= .08 * error;
    }
    final id = key(s, context?.environmentKey ?? network), h = history.putIfAbsent(key(s, context?.environmentKey ?? network), () => [0, 0]);
    h[0] += success ? 1 : 0; h[1]++; samples++;
    if (history.length > 500) history.remove(history.keys.firstWhere((k) => k != id));
  }
  String encode() => jsonEncode({'version': 2, 'journal': journal, 'hidden': hidden, 'output': output, 'history': history, 'samples': samples});
  static AdaptiveSelector decode(String? raw) {
    final model = AdaptiveSelector();
    if (raw == null) return model;
    try {
      final j = jsonDecode(raw) as Map;
      if (j['version'] != 2) return model;
      final h = (j['hidden'] as List).map((r) => (r as List).map((n) => (n as num).toDouble()).toList()).toList();
      final o = (j['output'] as List).map((n) => (n as num).toDouble()).toList();
      if (h.length != 6 || h.any((r) => r.length != 19) || o.length != 7 || [...h.expand((r) => r), ...o].any((v) => !v.isFinite)) return model;
      final records = Map<String, dynamic>.from(j['history'] as Map);
      if (records.length > 500) return model;
      final parsed = records.map((k, v) => MapEntry(k, (v as List).cast<int>()));
      if (parsed.values.any((r) => r.length != 2 || r[0] < 0 || r[1] < r[0])) return model;
      final entries = j['journal'];
      if (entries is List && entries.length <= 200) {
        model.journal.addAll(entries.map((e) => Map<String, dynamic>.from(e as Map)));
      }
      model.hidden = h; model.output = o; model.history.addAll(parsed); model.samples = j['samples'] as int;
    } catch (_) { return AdaptiveSelector(); }
    return model;
  }
}
