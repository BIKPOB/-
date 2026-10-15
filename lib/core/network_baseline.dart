import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'network_context.dart';

/// Short HTTPS sample, not the line rate reported by the network adapter.
class NetworkBaseline {
  const NetworkBaseline(this.session, this.type, this.time, this.bytesPerSecond, this.latencyMs);
  final String session, type;
  final DateTime time;
  final int bytesPerSecond, latencyMs;
  bool fresh(NetworkContext network, DateTime now) => !network.ambiguous &&
    network.sameConnection(NetworkContext(type: type, session: session)) &&
    now.difference(time) >= Duration.zero && now.difference(time) < const Duration(hours: 2);
  int get target => (bytesPerSecond * .6).round();
  Map<String, dynamic> toJson() => {'session': session, 'type': type,
    'time': time.millisecondsSinceEpoch, 'bytesPerSecond': bytesPerSecond, 'latencyMs': latencyMs};
  factory NetworkBaseline.fromJson(Map<dynamic, dynamic> m) => NetworkBaseline(
    m['session'] as String, m['type'] as String, DateTime.fromMillisecondsSinceEpoch((m['time'] as num).toInt()),
    (m['bytesPerSecond'] as num).toInt(), (m['latencyMs'] as num).toInt());
  String get label => 'Без VPN: ${(bytesPerSecond * 8 / 1000000).toStringAsFixed(1)} Мбит/с · HTTPS $latencyMs мс';
}

class BaselineMonitor {
  static const channel = MethodChannel('quietvpn/baseline');
  HttpClient? _client;
  int _epoch = 0;
  bool _running = false;
  NetworkBaseline? latest;
  String status = 'свежий прямой замер пока недоступен';
  Future<void> pause(bool value) async {
    if (value) { _epoch++; _client?.close(force: true); }
    if (Platform.isAndroid) await channel.invokeMethod<void>('pause', value);
  }
  Future<NetworkBaseline?> tick(NetworkContext context, {Future<NetworkContext> Function()? readNetwork}) async {
    if (Platform.isAndroid) {
      final m = await channel.invokeMapMethod<dynamic, dynamic>('tick');
      if (m != null && m['bytesPerSecond'] != null) latest = NetworkBaseline.fromJson(m);
      return latest;
    }
    if (context.vpnPresent) { status = 'прямой замер отложен: активен виртуальный сетевой адаптер или VPN'; return latest; }
    if (context.ambiguous) { status = 'прямой замер отложен: несколько равноприоритетных сетей'; return latest; }
    if (context.type == 'offline') { status = 'нет доступной сети'; return latest; }
    if (!Platform.isWindows || _running) return latest;
    _running = true;
    final epoch = _epoch;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/network-baseline.json');
      Map<String, dynamic> saved = {};
      try { saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>; } catch (_) { }
      if (latest == null && saved['sample'] is Map) latest = NetworkBaseline.fromJson(saved['sample'] as Map);
      final now = DateTime.now();
      final limited = context.metered != false; // Unknown Windows cost is treated as metered.
      final interval = Duration(minutes: limited ? 120 : 30);
      final last = DateTime.fromMillisecondsSinceEpoch((saved['attempt'] as num?)?.toInt() ?? 0);
      if (now.difference(last) < const Duration(minutes: 5) ||
          (latest?.fresh(context, now) == true && saved['attemptSession'] == context.session && now.difference(last) < interval)) {
        status = 'ожидание следующего прямого замера (после неудачи — не раньше 5 минут)';
        return latest;
      }
      final day = now.toUtc().toIso8601String().substring(0, 10);
      final used = saved['day'] == day ? (saved['used'] as num?)?.toInt() ?? 0 : 0;
      final size = limited ? 1048576 : 4194304;
      if (used + size > (limited ? 8 : 32) * 1048576) { status = 'достигнут суточный лимит трафика прямых замеров'; return latest; }
      if (epoch != _epoch) return latest;
      // Reserve the complete payload before starting; failed/interrupted tests count too.
      saved.addAll({'day': day, 'used': used + size, 'attempt': now.millisecondsSinceEpoch, 'attemptSession': context.session});
      await file.writeAsString(jsonEncode(saved), flush: true);
      if (epoch != _epoch) return latest;
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      _client = client;
      final deadline = Timer(const Duration(seconds: 12), () => client.close(force: true));
      try {
        final watch = Stopwatch()..start();
        final request = await client.getUrl(Uri.https('speed.cloudflare.com', '/__down', {'bytes': '$size'}));
        request.followRedirects = false;
        request.headers.set('Accept-Encoding', 'identity');
        final response = await request.close();
        if (response.statusCode != 200) throw const HttpException('Baseline HTTP status');
        final latency = watch.elapsedMilliseconds;
        watch.reset();
        var bytes = 0;
        await for (final chunk in response) {
          if (epoch != _epoch || bytes + chunk.length > size) throw const HttpException('Baseline cancelled');
          bytes += chunk.length;
        }
        final elapsed = watch.elapsedMilliseconds;
        if (bytes != size || elapsed < 20 || epoch != _epoch) return latest;
        if (readNetwork != null) {
          final after = await readNetwork();
          if (after.ambiguous || after.vpnPresent || !context.sameConnection(after) || epoch != _epoch) return latest;
        }
        latest = NetworkBaseline(context.session, context.type, now, bytes * 1000 ~/ elapsed, latency);
        saved['sample'] = latest!.toJson();
        await file.writeAsString(jsonEncode(saved), flush: true);
      } finally { deadline.cancel(); client.close(force: true); _client = null; }
    } catch (error) {
      status = 'прямой HTTPS-замер не завершён: ${error.runtimeType}; повтор не раньше 5 минут';
    } finally { _running = false; }
    return latest;
  }
  void dispose() { _epoch++; _client?.close(force: true); }
}
