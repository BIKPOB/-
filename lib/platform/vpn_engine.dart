import '../core/models.dart';

/// Engines may select a short TLS/HTTPS proof before a separate speed sample.
abstract interface class QuickProbeSupport {
  void setQuickProbe(bool enabled);
}

abstract interface class VpnEngine {
  Stream<EngineEvent> get events;
  Future<void> initialize();
  Future<void> connect(VpnServer server, Credentials? credentials);
  Future<void> disconnect();
  Future<void> reconcile();
  Future<void> dispose();
}
