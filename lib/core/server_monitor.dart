import 'dart:async';
import 'dart:io';
import 'models.dart';

typedef Probe = Future<HealthResult> Function(VpnServer server);

class ServerMonitor {
  ServerMonitor({Probe? probe}) : _probe = probe;
  final Probe? _probe;
  final Set<Socket> _sockets = {};
  int _generation = 0;
  Future<Map<String, HealthResult>>? _pending;

  Future<Map<String, HealthResult>> sample(List<VpnServer> candidates) {
    // A second caller joins the current batch, never starts another worker pool.
    return _pending ??= _sample(candidates).whenComplete(() => _pending = null);
  }
  Future<Map<String, HealthResult>> _sample(List<VpnServer> candidates) async {
    final generation = _generation;
    final servers = candidates.take(10).toList();
    final results = <String, HealthResult>{};
    var cursor = 0;
    Future<void> worker() async {
      while (generation == _generation && cursor < servers.length) {
        final server = servers[cursor++];
        HealthResult result;
        try { result = await (_probe?.call(server) ?? _tcp(server)); }
        catch (_) { result = const HealthResult(Reachability.unreachable); }
        if (generation == _generation) results[server.id] = result;
      }
    }
    await Future.wait(List.generate(3, (_) => worker()));
    return results;
  }
  Future<HealthResult> _tcp(VpnServer server) async {
    if (server.transport != 'tcp') return const HealthResult(Reachability.notMeasured);
    final watch = Stopwatch()..start();
    final generation = _generation;
    final socket = await Socket.connect(server.host, server.port, timeout: const Duration(milliseconds: 1500));
    _sockets.add(socket);
    try {
      if (generation != _generation) return const HealthResult(Reachability.paused);
      return HealthResult(Reachability.reachable, watch.elapsedMilliseconds);
    } finally { socket.destroy(); _sockets.remove(socket); }
  }
  void cancel() {
    _generation++;
    for (final socket in _sockets) { socket.destroy(); }
    _sockets.clear();
  }
}

/// Bounded round-robin queue; UDP entries never consume a TCP probe slot.
class ProbeQueue {
  int _cursor = 0;
  List<VpnServer> next(List<VpnServer> servers) {
    final tcp = servers.where((s) => s.transport == 'tcp').toList();
    if (tcp.isEmpty) return [];
    final batch = List.generate(tcp.length < 10 ? tcp.length : 10,
      (i) => tcp[(_cursor + i) % tcp.length]);
    _cursor = (_cursor + batch.length) % tcp.length;
    return batch;
  }
}
