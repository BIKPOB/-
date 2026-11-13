import 'dart:async';
import 'network_analysis.dart';
import 'network_context.dart';

/// Small, direct HTTPS controls. This is not a VPN ping or proof of filtering.
class NetworkAccessSnapshot {
  NetworkAccessSnapshot(this.context, this.time, Map<String, int?> results)
      : results = Map.unmodifiable(results);
  final NetworkContext context;
  final DateTime time;
  final Map<String, int?> results;
  int get domestic => results.entries.where((e) =>
      NetworkAccessMonitor.domesticHosts.contains(e.key) && e.value != null).length;
  int get external => results.entries.where((e) =>
      NetworkAccessMonitor.externalHosts.contains(e.key) && e.value != null).length;
  bool get possibleRestrictions => domestic == 2 && external == 0;
  bool fresh(NetworkContext current, DateTime now,
      {Duration maxAge = const Duration(minutes: 5)}) =>
      !current.vpnPresent && !current.ambiguous && current.type != 'offline' &&
      context.environmentKey == current.environmentKey &&
      context.sameConnection(current) && !now.difference(time).isNegative &&
      now.difference(time) < maxAge;
  String learningOutcome(String outcome, NetworkContext current, DateTime now) =>
      fresh(current, now) && possibleRestrictions &&
          (outcome == 'unconfirmed' || outcome == 'slow_or_unstable')
      ? 'network_limited' : outcome;
  String get label => possibleRestrictions
      ? 'Возможны ограничения сети: российские HTTPS-адреса отвечают, внешние не подтверждены'
      : external == 2 ? 'Оба внешних HTTPS-адреса доступны'
      : external == 1 ? 'Внешний доступ подтверждён частично'
      : 'Доступ в интернет не подтверждён; причина пока неизвестна';
  String get report => '$label. Контроль: российские $domestic/2, внешние $external/2. '
      'Это проверка отдельных адресов, не доказательство белого списка.\n'
      '${results.entries.map((e) => "${e.key}: ${e.value == null ? "нет подтверждения" : "${e.value} мс"}").join("; ")}';
}

class NetworkAccessMonitor {
  NetworkAccessMonitor({NetworkAnalyzer? analyzer})
      : _analyzer = analyzer ?? NetworkAnalyzer();
  final NetworkAnalyzer _analyzer;
  int _epoch = 0;
  static const domesticHosts = {'yandex.ru', 'vk.com'};
  static const externalHosts = {'www.gstatic.com', 'cp.cloudflare.com'};
  static const endpoints = [
    'https://yandex.ru/robots.txt',
    'https://vk.com/robots.txt',
    'https://www.gstatic.com/generate_204',
    'https://cp.cloudflare.com/generate_204',
  ];
  void cancel() { _epoch++; _analyzer.cancel(); }
  Future<NetworkAccessSnapshot> check(NetworkContext context, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (context.vpnPresent || context.ambiguous || context.type == 'offline') {
      throw StateError('Нет однозначного прямого маршрута');
    }
    final epoch = _epoch;
    final entries = await Future.wait(endpoints.map((address) async {
      final uri = Uri.parse(address);
      int? elapsed;
      try {
        elapsed = await _analyzer.https(uri, maxBytes: 1024, timeout: timeout)
            .timeout(timeout);
        if (elapsed < 1) elapsed = null;
      } catch (_) { elapsed = null; }
      return MapEntry(uri.host, elapsed);
    }));
    if (epoch != _epoch) throw StateError('Проверка отменена');
    return NetworkAccessSnapshot(context, DateTime.now(), Map.fromEntries(entries));
  }
}
