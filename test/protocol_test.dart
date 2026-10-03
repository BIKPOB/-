import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/profile_policy.dart';
import 'package:quiet_vpn/data/catalog_repository.dart';
const config = '''[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
DNS = 1.1.1.1
[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = example.com:51820
''';
void main() {
  test('WireGuard config is detected and given an initial keepalive', () {
    final parsed = ProfilePolicy.parse(config);
    expect(parsed.protocol, 'wireguard'); expect(parsed.port, 51820);
    expect(parsed.needsAuth, isFalse); expect(parsed.text, contains('PersistentKeepalive = 25'));
  });
  test('AmneziaWG fields select AmneziaWG without stripping obfuscation', () {
    final parsed = ProfilePolicy.parse(config.replaceFirst('[Peer]', 'Jc = 4\nJmin = 40\nJmax = 70\nH1 = 123\n[Peer]'));
    expect(parsed.protocol, 'amneziawg'); expect(parsed.text, contains('Jc = 4'));
  });
  test('executable hooks, invalid keys and multiple peers are rejected', () {
    expect(() => ProfilePolicy.parse(config.replaceFirst('[Peer]', 'PostUp = malicious\n[Peer]')), throwsFormatException);
    expect(() => ProfilePolicy.parse(config.replaceFirst('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', 'bad')), throwsFormatException);
    expect(() => ProfilePolicy.parse('$config\n[Peer]\n'), throwsFormatException);
  });
  test('live VPN Gate fixture contains compatible servers', () {
    final file = File('build/live-catalog.csv');
    if (!file.existsSync()) return;
    final result = CatalogRepository.parseCsv(file.readAsStringSync());
    expect(result.servers, isNotEmpty, reason: 'Live feed must not be silently rejected');
  });
}
