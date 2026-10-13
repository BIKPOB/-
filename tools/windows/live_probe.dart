import 'dart:io';
import '../../lib/platform/windows_probe.dart';

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
  } finally { probe.cancel(); }
}
