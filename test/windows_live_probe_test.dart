import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/platform/windows_probe.dart';

void main() {
  test('live DNS and HTTPS traverse Windows TUN interface', () async {
    final probe = WindowsProbe();
    try {
      final result = await probe.measure(Platform.environment['QUIET_TUNNEL_ADDRESS']!);
      expect(result['delay'], greaterThanOrEqualTo(0), reason: result['detail'] as String);
      expect(result['bytesPerSecond'], greaterThan(0));
    } finally { probe.cancel(); }
  }, skip: !Platform.isWindows || !Platform.environment.containsKey('QUIET_TUNNEL_ADDRESS'));
}
