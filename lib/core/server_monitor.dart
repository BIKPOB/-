import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'models.dart';

typedef Probe = Future<HealthResult> Function(VpnServer server);
typedef Ping = Future<int?> Function(String host);

class ServerMonitor {
  ServerMonitor({Probe? probe, Ping? ping}) : _probe = probe, _ping = ping;
  final Probe? _probe;
  final Ping? _ping;
  final Set<Socket> _sockets = {};
  final Set<Process> _processes = {};
  int _generation = 0;
  Future<Map<String, HealthResult>>? _pending;

  Future<Map<String, HealthResult>> sample(List<VpnServer> candidates,
      {void Function(String id, HealthResult result)? onResult}) {
    if (_pending != null) return _pending!;
    final generation = _generation;
    return _pending = _sample(candidates, generation, onResult).whenComplete(() {
      if (generation == _generation) _pending = null;
    });
  }
  Future<Map<String, HealthResult>> _sample(List<VpnServer> candidates, int generation,
      void Function(String, HealthResult)? onResult) async {
    final results = <String, HealthResult>{};
    // Every endpoint starts in this sweep. Share ICMP for profiles on one host.
    final pings = <String, Future<int?>>{};
    await Future.wait(candidates.map((server) async {
      HealthResult result;
      try {
        if (_probe != null) {
          result = await _probe(server);
        } else {
          final ms = await pings.putIfAbsent(server.host,
            () => (_ping?.call(server.host) ?? _icmp(server.host, generation)));
          if (generation != _generation) return;
          result = ms != null
            ? HealthResult(Reachability.reachable, ms, 'ICMP')
            : await _tcp(server, generation);
        }
      } catch (_) { result = const HealthResult(Reachability.notMeasured); }
      if (generation == _generation) {
        results[server.id] = result;
        onResult?.call(server.id, result);
      }
    }));
    return results;
  }
  static int? parsePing(String output) {
    final match = RegExp(r'time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms', caseSensitive: false).firstMatch(output);
    final value = double.tryParse(match?.group(1) ?? '');
    return value?.ceil();
  }
  Future<int?> _icmp(String host, int generation) async {
    if (!Platform.isAndroid || !RegExp(r'^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$').hasMatch(host)) return null;
    Process? process;
    try {
      process = await Process.start('/system/bin/ping', ['-n', '-c', '1', '-W', '2', '-w', '3', host]);
      _processes.add(process);
      if (generation != _generation) { process.kill(ProcessSignal.sigkill); return null; }
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(const Duration(seconds: 4));
      await errors;
      final text = await output;
      return code == 0 ? parsePing(text) : null;
    } catch (_) { return null; }
    finally {
      if (process != null) { process.kill(ProcessSignal.sigkill); _processes.remove(process); }
    }
  }
  Future<HealthResult> _tcp(VpnServer server, int generation) async {
    if (server.transport != 'tcp') return const HealthResult(Reachability.notMeasured);
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(server.host, server.port, timeout: const Duration(milliseconds: 1500));
      _sockets.add(socket);
      try {
        if (generation != _generation) return const HealthResult(Reachability.paused);
        return HealthResult(Reachability.reachable, watch.elapsedMilliseconds, 'TCP');
      } finally { socket.destroy(); _sockets.remove(socket); }
    } on SocketException { return const HealthResult(Reachability.unreachable); }
  }
  void cancel() {
    _generation++;
    _pending = null;
    for (final socket in _sockets) { socket.destroy(); }
    _sockets.clear();
    for (final process in _processes) { process.kill(ProcessSignal.sigkill); }
    _processes.clear();
  }
}
