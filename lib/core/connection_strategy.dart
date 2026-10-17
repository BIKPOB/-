import 'models.dart';

/// Prefer proven routes, then encrypted VLESS transports. A TCP response is
/// ordering evidence only; it never confirms a working VPN.
class ConnectionStrategy {
  static bool protectedVless(VpnServer server) {
    if (server.protocol != 'vless') return false;
    final security = Uri.tryParse(server.profile)?.queryParameters['security'];
    return security == 'tls' || security == 'reality';
  }
  static List<VpnServer> select(List<VpnServer> ranked, {
    required int limit, required int Function(VpnServer) priority,
  }) {
    final result = <VpnServer>[];
    for (final tier in [1, 0, -1]) {
      final group = ranked.where((s) => priority(s) == tier).toList();
      if (tier == 1) {
        result.addAll(group.take(limit - result.length));
      } else {
        final protected = group.where(protectedVless).toList();
        final alternatives = group.where((s) => !protectedVless(s)).toList();
        var p = 0, a = 0;
        while (result.length < limit && (p < protected.length || a < alternatives.length)) {
          for (var i = 0; i < 2 && p < protected.length && result.length < limit; i++) {
            result.add(protected[p++]);
          }
          if (a < alternatives.length && result.length < limit) result.add(alternatives[a++]);
        }
      }
      if (result.length >= limit) break;
    }
    return result;
  }
}
