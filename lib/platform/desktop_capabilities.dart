import '../core/network_context.dart';

abstract interface class DesktopCapabilities {
  Future<NetworkContext> readNetwork();
  Future<Map<String, dynamic>> probeTunnel();
  Future<String> diagnostics();
}
