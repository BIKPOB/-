import 'dart:async';
import '../core/models.dart';

/// Engines may select a short TLS/HTTPS proof before a separate speed sample.
abstract interface class QuickProbeSupport {
  void setQuickProbe(bool enabled);
}

/// Keeps explicitly requested VPN search active across Android screen lock.
abstract interface class SearchSessionHost {
  Future<void> beginSearchSession({required bool deep});
  Future<void> endSearchSession();
}

/// Receives user cancellation from Android's persistent search notification.
abstract interface class SearchCancelHost {
  Stream<void> get searchCancelRequests;
}

abstract interface class VpnEngine {
  Stream<EngineEvent> get events;
  Future<void> initialize();
  Future<void> connect(VpnServer server, Credentials? credentials);
  Future<void> disconnect();
  Future<void> reconcile();
  Future<void> dispose();
}
