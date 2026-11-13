import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'connection_strategy.dart';
import 'models.dart';
import 'network_context.dart';

/// Recovery evidence is separate from normal-network speed preferences.
/// Only confirmed system VPN successes are passed to remember().
class RecoveryHistory {
  RecoveryHistory(dynamic saved) {
    if (saved is List) {
      for (final row in saved.whereType<Map>().take(128)) {
        final time = DateTime.tryParse(row['time']?.toString() ?? '');
        if (row['network'] is String && row['profile'] is String && time != null) {
          entries.add({'network':row['network'], 'profile':row['profile'],
            'time':time.toUtc().toIso8601String()});
        }
      }
    }
  }
  final entries = <Map<String,String>>[];
  static String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
  static String _network(NetworkContext context) => _hash(context.environmentKey);
  static String _profile(VpnServer server) => _hash(ConnectionStrategy.profileKey(server));
  bool worked(VpnServer server, NetworkContext context, DateTime now) {
    final network = _network(context), profile = _profile(server);
    return entries.any((row) {
        final age = now.toUtc().difference(DateTime.parse(row['time']!));
        return row['network'] == network && row['profile'] == profile &&
            !age.isNegative && age < const Duration(days:7);
      });
  }
  void remember(VpnServer server, NetworkContext context, DateTime now) {
    if (context.ambiguous || context.type == 'offline') return;
    final network = _network(context), profile = _profile(server);
    entries.removeWhere((row) => row['network'] == network && row['profile'] == profile);
    entries.insert(0, {'network':network,'profile':profile,'time':now.toUtc().toIso8601String()});
    if (entries.length > 128) entries.removeRange(128,entries.length);
  }
}

/// Diversity changes scheduling only. It never marks an untested server alive.
class RecoveryPlanner {
  static String endpoint(VpnServer server) => server.host.toLowerCase();
  static String family(VpnServer server) {
    final uri = Uri.tryParse(server.profile);
    return '${server.protocol}|${uri?.queryParameters['type'] ?? server.transport}|${uri?.queryParameters['security'] ?? ""}';
  }
  static String subnet(VpnServer server) {
    final ip = InternetAddress.tryParse(server.host);
    if (ip == null) return endpoint(server);
    final bytes = ip.rawAddress;
    return bytes.take(ip.type == InternetAddressType.IPv4 ? 3 : 6).join('.');
  }
  static List<VpnServer> order(List<VpnServer> ranked, RecoveryHistory history,
      NetworkContext context, DateTime now) {
    final unique = <String>{};
    final pool = ranked.where((s) => unique.add(ConnectionStrategy.profileKey(s))).toList();
    final result = <VpnServer>[];
    final endpoints = <String>{}, subnets = <String>{}, families = <String>{};
    void add(VpnServer server) {
      result.add(server); endpoints.add(endpoint(server));
      subnets.add(subnet(server)); families.add(family(server));
    }
    // Recheck successes in this recovery context first, never trust a stale ping.
    for (final server in pool.where((s) => history.worked(s,context,now))) { add(server); }
    final added = result.map(ConnectionStrategy.profileKey).toSet();
    final remaining = [
      for (final server in pool)
        if (!added.contains(ConnectionStrategy.profileKey(server)))
          (server:server, endpoint:endpoint(server), subnet:subnet(server), family:family(server)),
    ];
    // Four linear passes retain every candidate without quadratic URI parsing.
    for (var pass=0;pass<4;pass++) {
      for (final entry in remaining) {
        final key=ConnectionStrategy.profileKey(entry.server);
        if (added.contains(key)) continue;
        if (pass < 3 && endpoints.contains(entry.endpoint)) continue;
        if (pass < 2 && subnets.contains(entry.subnet)) continue;
        if (pass == 0 && families.contains(entry.family)) continue;
        add(entry.server); added.add(key);
      }
    }
    return result;
  }
}
