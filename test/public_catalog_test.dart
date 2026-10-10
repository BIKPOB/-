import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/data/public_catalog.dart';
const uuid = '12345678-1234-1234-1234-123456789abc';
void main() {
  test('public subscription isolates invalid entries, deduplicates labels, supports base64', () {
    const lines = 'vless://$uuid@example.com:443#one\nvless://$uuid@example.com:443#two\n'
      'vless://broken@example.com:443\nss://aes-256-gcm:secret@example.org:443\n'
      'vless://$uuid@127.0.0.1:443\nvmess://unsupported';
    for (final input in [lines, base64.encode(utf8.encode(lines))]) {
      final result = PublicCatalog.parse(input);
      expect(result.servers.length, 2);
      expect(result.servers.map((s) => s.protocol), ['vless', 'shadowsocks']);
      expect(result.skipped, 2);
    }
  });
  test('catalog limits are independent per protocol and local addresses are excluded', () {
    final lines = List.generate(120, (i) => 'vless://$uuid@node$i.example.com:443');
    lines.add('ss://aes-256-gcm:secret@example.org:443');
    expect(PublicCatalog.parse(lines.join('\n')).servers.length, 101);
    for (final host in ['localhost', 'router.local', '10.1.2.3', '192.168.1.1', '169.254.1.2', '100.64.1.2', '::1', 'fc00::1', '::ffff:127.0.0.1']) {
      expect(PublicCatalog.publicHost(host), false, reason: host);
    }
    expect(() => PublicCatalog.parse('invalid'), throwsFormatException);
    expect(() => PublicCatalog.parse('a' * (PublicCatalog.maxBytes + 1)), throwsFormatException);
  });
  test('bundled snapshot provides both supported protocols without a network', () {
    final result = PublicCatalog.parse(File('assets/public-proxies.txt').readAsStringSync(), bundled: true);
    expect(result.bundled, true);
    expect(result.servers.where((s) => s.protocol == 'vless'), isNotEmpty);
    expect(result.servers.where((s) => s.protocol == 'shadowsocks'), isNotEmpty);
    // Counts only: never log credentials from a subscription.
    // ignore: avoid_print
    print('Bundled compatible: VLESS=${result.servers.where((s) => s.protocol == 'vless').length}, SS=${result.servers.where((s) => s.protocol == 'shadowsocks').length}');
  });
}
