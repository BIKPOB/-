enum ConnectionState { connecting, connected, disconnected, error }
enum Reachability { unknown, reachable, unreachable, notMeasured, paused }

class VpnServer {
  const VpnServer({required this.id, required this.name, required this.country,
    required this.countryCode, required this.host, required this.port,
    required this.transport, required this.profile, required this.source,
    this.score = 0, this.protocol = 'openvpn'});
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
  const HealthResult(this.state, [this.milliseconds, this.method = '']);
  final String method;
  final Reachability state;
  final int? milliseconds;
}

class EngineEvent {
  const EngineEvent(this.state, [this.message]);
  final ConnectionState state;
  final String? message;
}

class Credentials {
  const Credentials(this.username, this.password);
  final String username, password;
}
