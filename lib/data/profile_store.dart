import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/models.dart';
import '../core/profile_policy.dart';

class ProfileStore {
  final _storage = const FlutterSecureStorage();
  Future<List<VpnServer>> load() async {
    final raw = await _storage.read(key: 'imports.v1');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((j) {
      final server = VpnServer.fromJson(Map<String, dynamic>.from(j as Map));
      ProfilePolicy.parse(server.profile);
      return server;
    }).toList();
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
