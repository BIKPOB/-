enum ConnectionState { connecting, connected, disconnected, error }
enum Reachability { unknown, reachable, unreachable, notMeasured, paused }

class VpnServer {
  const VpnServer({required this.id, required this.name, required this.country,
    required this.countryCode, required this.host, required this.port,
    required this.transport, required this.profile, required this.source,
    this.score = 0, this.protocol = 'wireguard'});
  final String id, name, country, countryCode, host, transport, profile, source, protocol;
  final int port, score;
  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'country': country, 'countryCode': countryCode,
    'host': host, 'port': port, 'transport': transport, 'profile': profile,
    'source': source, 'score': score, 'protocol': protocol,
  };
  factory VpnServer.fromJson(Map<String, dynamic> j) => VpnServer(
    id: j['id'] as String, name: j['name'] as String, country: j['country'] as String,
    countryCode: j['countryCode'] as String, host: j['host'] as String,
    port: j['port'] as int, transport: j['transport'] as String,
    profile: j['profile'] as String, source: j['source'] as String,
    protocol: j['protocol'] as String? ?? 'openvpn',
    score: j['score'] as int? ?? 0,
  );
}

class HealthResult {
  const HealthResult(this.state, [this.milliseconds, this.method = '', this.checkedAt]);
  final DateTime? checkedAt;
  bool get protocolVerified => state == Reachability.reachable &&
    (method == 'HTTPS через сервер' || method == 'HTTPS через VPN') &&
    checkedAt != null && DateTime.now().difference(checkedAt!) >= Duration.zero &&
    DateTime.now().difference(checkedAt!) < const Duration(minutes: 15);
  final String method;
  final Reachability state;
  final int? milliseconds;
}

class EngineEvent {
  const EngineEvent(this.state, [this.message, this.quality = true, this.bytesPerSecond,
    this.latencyMs, this.httpsVerified = false]);
  final int? bytesPerSecond;
  /// HTTPS verified through this VPN even if a speed sample is pending.
  final bool httpsVerified;
  /// HTTPS response delay produced by an actual VPN tunnel probe, if any.
  final int? latencyMs;
  final bool quality;
  final ConnectionState state;
  final String? message;
}

class Credentials {
  const Credentials(this.username, this.password);
  final String username, password;
}

/// Cache confirmed HTTPS separately from failed or interrupted checks. A socket
/// response is never treated as an authenticated protocol handshake.
class ProtocolHealthPolicy {
  static const verifiedTtl = Duration(minutes: 15);
  static const retryTtl = Duration(minutes: 2);
  static bool needsProbe(HealthResult? result, DateTime now) {
    final checked = result?.checkedAt;
    if (checked == null) return true;
    final elapsed = now.difference(checked);
    if (elapsed.isNegative) return true;
    final verified = result!.state == Reachability.reachable &&
        (result.method == 'HTTPS через сервер' || result.method == 'HTTPS через VPN');
    return elapsed >= (verified ? verifiedTtl : retryTtl);
  }
}
