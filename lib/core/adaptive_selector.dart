import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'models.dart';

/// Small on-device neural classifier: 8 inputs, 6 tanh units, sigmoid output.
/// Starts untrained; learns only from verified connections, not ICMP responses.
class AdaptiveSelector {
  AdaptiveSelector() {
    final random = Random(754);
    hidden = List.generate(6, (_) => List.generate(9, (_) => (random.nextDouble() - .5) * .2));
  }
  late List<List<double>> hidden;
  List<double> output = List.filled(7, 0);
  final history = <String, List<int>>{};
  int samples = 0;
  String key(VpnServer s, String network) => sha256.convert(utf8.encode('$network|${s.protocol}|${s.host}|${s.port}')).toString();
  List<double> features(VpnServer s, String network, int? latency) {
    final h = history[key(s, network)] ?? [0, 0];
    return [s.protocol == 'wireguard' ? 1 : 0, s.protocol == 'vless' ? 1 : 0,
      s.protocol == 'shadowsocks' ? 1 : 0, network == 'wifi' ? 1 : 0,
      network == 'mobile' ? 1 : 0, latency == null ? 0 : 1 / (1 + latency / 200),
      (h[0] + 1) / (h[1] + 2), min(h[1], 10) / 10];
  }
  List<double> _activation(List<double> x) => hidden.map((w) {
    var z = w.last;
    for (var i = 0; i < 8; i++) { z += w[i] * x[i]; }
    final e = exp(2 * z.clamp(-15, 15));
    return (e - 1) / (e + 1);
  }).toList();
  double predict(List<double> x) {
    final h = _activation(x);
    var z = output.last;
    for (var j = 0; j < 6; j++) { z += output[j] * h[j]; }
    return 1 / (1 + exp(-z.clamp(-30, 30)));
  }
  double score(VpnServer s, String network, int? latency) {
    final x = features(s, network, latency);
    return .65 * predict(x) + .25 * x[6] + .1 * x[5];
  }
  void observe(VpnServer s, String network, int? latency, {required bool success}) {
    final x = features(s, network, latency);
    for (var step = 0; step < 4; step++) {
      final h = _activation(x), old = List<double>.from(output);
      final error = predict(x) - (success ? 1 : 0);
      for (var j = 0; j < 6; j++) {
        final delta = error * old[j] * (1 - h[j] * h[j]);
        for (var i = 0; i < 8; i++) { hidden[j][i] -= .08 * delta * x[i]; }
        hidden[j][8] -= .08 * delta;
        output[j] -= .08 * error * h[j];
      }
      output[6] -= .08 * error;
    }
    final id = key(s, network), h = history.putIfAbsent(key(s, network), () => [0, 0]);
    h[0] += success ? 1 : 0; h[1]++; samples++;
    if (history.length > 500) history.remove(history.keys.firstWhere((k) => k != id));
  }
  String encode() => jsonEncode({'hidden': hidden, 'output': output, 'history': history, 'samples': samples});
  static AdaptiveSelector decode(String? raw) {
    final model = AdaptiveSelector();
    if (raw == null) return model;
    try {
      final j = jsonDecode(raw) as Map;
      final h = (j['hidden'] as List).map((r) => (r as List).map((n) => (n as num).toDouble()).toList()).toList();
      final o = (j['output'] as List).map((n) => (n as num).toDouble()).toList();
      if (h.length != 6 || h.any((r) => r.length != 9) || o.length != 7 || [...h.expand((r) => r), ...o].any((v) => !v.isFinite)) return model;
      final records = Map<String, dynamic>.from(j['history'] as Map);
      if (records.length > 500) return model;
      final parsed = records.map((k, v) => MapEntry(k, (v as List).cast<int>()));
      if (parsed.values.any((r) => r.length != 2 || r[0] < 0 || r[1] < r[0])) return model;
      model.hidden = h; model.output = o; model.history.addAll(parsed); model.samples = j['samples'] as int;
    } catch (_) { return AdaptiveSelector(); }
    return model;
  }
}
