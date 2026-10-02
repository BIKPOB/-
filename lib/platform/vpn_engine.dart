import '../core/models.dart';

abstract interface class VpnEngine {
  Stream<EngineEvent> get events;
  Future<void> initialize();
  Future<void> connect(VpnServer server, Credentials? credentials);
  Future<void> disconnect();
  Future<void> reconcile();
  Future<void> dispose();
}
