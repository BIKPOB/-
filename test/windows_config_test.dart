import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/platform/windows_config.dart';
import 'package:quiet_vpn/platform/windows_probe.dart';

void main() {
  test('unprotected public VLESS is rejected before starting Windows TUN', () {
    expect(() => WindowsConfig.xray(
      'vless://12345678-1234-1234-1234-123456789abc@example.com:443?security=none',
      '203.0.113.1'), throwsFormatException);
  });
  test('Windows Xray routes IPv4 and IPv6, protects DNS and preserves TLS name', () {
    final config = WindowsConfig.xray('vless://12345678-1234-1234-1234-123456789abc@example.com:443?security=tls&sni=verified.example', '203.0.113.1');
    final inbound = (config['inbounds'] as List).single as Map;
    final settings = inbound['settings'] as Map;
    expect(settings['autoSystemRoutingTable'], ['0.0.0.0/0', '::/0']);
    expect(settings['autoOutboundsInterface'], 'auto');
    expect(settings['autoSystemWfpBlockLeak'], contains('dns'));
    final proxy = (config['outbounds'] as List).first as Map;
    expect(proxy['streamSettings']['tlsSettings']['serverName'], 'verified.example');
    expect(proxy['settings']['vnext'][0]['address'], '203.0.113.1');
    expect(config.toString(), isNot(contains('allowInsecure')));
  });
  test('DNS decoder validates transaction and truncation', () {
    final query = WindowsProbe.query('example.com', 1234);
    final reply = Uint8List.fromList([...query, 192, 12, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 1, 2, 3, 4]);
    reply[2] = 129; reply[3] = 128; reply[7] = 1;
    expect(WindowsProbe.answer(reply, 1234).address, '1.2.3.4');
    expect(() => WindowsProbe.answer(reply, 1235), throwsFormatException);
    expect(() => WindowsProbe.answer(Uint8List.sublistView(reply, 0, reply.length - 1), 1234), throwsFormatException);
  });
}
