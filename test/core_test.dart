import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/profile_policy.dart';
import 'package:quiet_vpn/core/management_protocol.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/data/catalog_repository.dart';

const fixture = 'client\ndev tun\nproto tcp\nremote 8.8.8.8 443\n<ca>\nTEST FIXTURE NOT A CERTIFICATE\n</ca>\n';

void main() {
  test('reject scripts and external files before native engine sees a profile', () {
    for (final directive in ['up evil.exe', 'plugin evil.dll', 'config other.ovpn',
      'script-security 2', 'auth-user-pass passwords.txt', 'ca cert.pem', 'management 0.0.0.0 9999']) {
      expect(() => ProfilePolicy.parse('$fixture$directive\n'), throwsFormatException);
    }
  });
  test('reject missing CA, nested blocks and a second remote', () {
    for (final text in ['client\nremote 8.8.8.8 443\n', '$fixture remote 1.1.1.1 443\n',
      'client\nremote 8.8.8.8 443\n<ca>\n<key>\n']) {
      expect(() => ProfilePolicy.parse(text), throwsFormatException);
    }
  });
  test('required TLS role validation and default route are preserved', () {
    final parsed = ProfilePolicy.parse(fixture);
    expect(parsed.port, 443); expect(parsed.transport, 'tcp');
    expect(parsed.text, contains('remote-cert-tls server'));
    expect(parsed.text, contains('redirect-gateway def1'));
    expect(ProfilePolicy.parse(parsed.text).text, parsed.text);
  });
  test('management connected requires SUCCESS and full state event', () {
    expect(parseManagementState('>STATE:123,CONNECTED,SUCCESS,10.0.0.2')?.state, ConnectionState.connected);
    expect(parseManagementState('>STATE:123,CONNECTED,FAILED'), isNull);
    expect(parseManagementState('CONNECTED SUCCESS'), isNull);
    expect(parseManagementState(">PASSWORD:Verification Failed: 'Auth'")?.state, ConnectionState.error);
    expect(() => managementQuote('user\npassword "Auth" bad'), throwsFormatException);
  });
  test('CSV handles quoted country and skips a mismatched endpoint', () {
    final encoded = base64Encode(utf8.encode(fixture));
    final csv = '*vpn_servers\n#HostName,IP,CountryLong,CountryShort,Score,OpenVPN_ConfigData_Base64\n'
      'fixture,8.8.8.8,"Test, Country",US,10,$encoded\n'
      'bad,1.1.1.1,Other,GB,5,$encoded\n*\n';
    final result = CatalogRepository.parseCsv(csv);
    expect(result.servers.length, 1); expect(result.rejected, 1);
    expect(result.servers.single.country, 'Test, Country');
  });
  test('public catalog cannot target loopback, private LAN or multicast', () {
    for (final address in ['127.0.0.1', '10.0.0.1', '192.168.1.1', '169.254.169.254', '100.64.0.1', '224.0.0.1', '::1']) {
      expect(CatalogRepository.isPublicIp(InternetAddress(address)), isFalse);
    }
  });
  test('worker pool caps concurrency at three and isolates a failed probe', () async {
    var live = 0, peak = 0, calls = 0;
    final monitor = ServerMonitor(probe: (server) async {
      calls++; live++; if (live > peak) peak = live;
      try {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (server.id == '0') throw const SocketException('refused');
        return const HealthResult(Reachability.reachable, 1);
      } finally { live--; }
    });
    final servers = List.generate(20, (i) => VpnServer(id: '$i', name: 'fixture', country: 'Test',
      countryCode: '--', host: '127.0.0.1', port: 1, transport: 'tcp', profile: fixture, source: 'test'));
    final result = await monitor.sample(servers);
    expect(calls, 10); expect(peak, 3); expect(live, 0);
    expect(result['0']?.state, Reachability.unreachable); expect(result.length, 10);
  });
  test('UDP has no invented TCP latency', () async {
    final result = await ServerMonitor().sample([const VpnServer(id: 'udp', name: 'test',
      country: 'Test', countryCode: '--', host: '127.0.0.1', port: 1,
      transport: 'udp', profile: fixture, source: 'test')]);
    expect(result['udp']?.state, Reachability.notMeasured);
    expect(result['udp']?.milliseconds, isNull);
  });
}
