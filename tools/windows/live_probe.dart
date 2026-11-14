import 'dart:io';
import 'package:quiet_vpn/platform/windows_probe.dart';

// Run outside the Flutter widget-test HTTP interception layer.
Future<void> main() async {
  final probe = WindowsProbe();
  try {
    final address = Platform.environment['QUIET_TUNNEL_ADDRESS'];
    if (!Platform.isWindows || address == null) throw StateError('Windows TUN address required');
    final result = await probe.measure(address);
    stdout.writeln(result['detail']);
    if ((result['delay'] as int) < 0 || (result['bytesPerSecond'] as int? ?? 0) <= 0) {
      throw StateError('Bound DNS/HTTPS/download failed');
    }
    final quick = await probe.measure(address,quick:true);
    stdout.writeln(quick['detail']);
    if ((quick['delay'] as num? ?? -1) < 0 || quick['httpsVerified'] != true ||
        quick['latencyMs'] == null || quick['bytesPerSecond'] != null || quick['quality'] != false) {
      throw StateError('Bound quick HTTPS confirmation failed or invented speed');
    }
  } finally { probe.cancel(); }
}
