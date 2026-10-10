import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/models.dart';
import '../core/profile_policy.dart';

class ProfileStore {
  final _storage = const FlutterSecureStorage();
  Future<List<VpnServer>> load() async {
    final raw = await _storage.read(key: 'imports.v1');
    if (raw == null) return [];
    return decodeProfiles(raw);
  }
  static List<VpnServer> decodeProfiles(String raw) {
    final result = <VpnServer>[];
    for (final entry in jsonDecode(raw) as List) {
      try {
        final json = Map<String, dynamic>.from(entry as Map);
        if (json['protocol'] == 'openvpn' || json['protocol'] == null) continue;
        final parsed = ProfilePolicy.parse(json['profile'] as String);
        json['protocol'] = parsed.protocol;
        json['profile'] = parsed.text;
        json['host'] = parsed.host; json['port'] = parsed.port;
        json['transport'] = parsed.transport;
        result.add(VpnServer.fromJson(json));
      } on FormatException { continue; }
    }
    return result;
  }
  Future<void> save(List<VpnServer> servers) => _storage.write(
    key: 'imports.v1', value: jsonEncode(servers.map((s) => s.toJson()).toList()));

  Future<Credentials?> credentials(String id) async {
    final raw = await _storage.read(key: 'auth.$id');
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return Credentials(j['username'] as String, j['password'] as String);
  }
  Future<void> saveCredentials(String id, Credentials credentials) => _storage.write(
    key: 'auth.$id', value: jsonEncode({'username': credentials.username, 'password': credentials.password}));
  Future<void> removeCredentials(String id) => _storage.delete(key: 'auth.$id');
}
