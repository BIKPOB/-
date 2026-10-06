import 'dart:convert';
import 'dart:async';
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
  test('all endpoints start together and one failed probe is isolated', () async {
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
    expect(calls, 20); expect(peak, 20); expect(live, 0);
    expect(result['0']?.state, Reachability.notMeasured); expect(result.length, 20);
  });
  test('UDP has no invented TCP latency', () async {
    final result = await ServerMonitor(ping: (_) async => null).sample([const VpnServer(id: 'udp', name: 'test',
      country: 'Test', countryCode: '--', host: '127.0.0.1', port: 1,
      transport: 'udp', profile: fixture, source: 'test')]);
    expect(result['udp']?.state, Reachability.notMeasured);
    expect(result['udp']?.milliseconds, isNull);
  });
  test('UDP gets real ICMP latency and hosts are deduplicated', () async {
    var calls = 0;
    final monitor = ServerMonitor(ping: (_) async { calls++; return 42; });
    final servers = List.generate(25, (i) => VpnServer(id: '$i', name: '', country: '',
      countryCode: '', host: '8.8.8.8', port: 1194, transport: 'udp', profile: '', source: 'test'));
    final updates = <String>[];
    final result = await monitor.sample(servers, onResult: (id, _) => updates.add(id));
    expect(calls, 1); expect(result.length, 25); expect(updates.length, 25);
    expect(result.values.every((r) => r.milliseconds == 42 && r.method == 'ICMP'), isTrue);
  });
  test('cancelled sweep cannot publish or clear a newer sweep', () async {
    final first = Completer<HealthResult>(), second = Completer<HealthResult>();
    var calls = 0;
    final monitor = ServerMonitor(probe: (_) => ++calls == 1 ? first.future : second.future);
    const server = VpnServer(id: 'x', name: '', country: '', countryCode: '',
      host: '8.8.8.8', port: 1194, transport: 'udp', profile: '', source: 'test');
    final updates = <String>[];
    final old = monitor.sample([server], onResult: (id, _) => updates.add('old'));
    monitor.cancel();
    final current = monitor.sample([server], onResult: (id, _) => updates.add('new'));
    first.complete(const HealthResult(Reachability.reachable, 1));
    expect(await old, isEmpty);
    expect(identical(current, monitor.sample([server])), isTrue);
    second.complete(const HealthResult(Reachability.reachable, 2));
    expect((await current)['x']?.milliseconds, 2); expect(updates, ['new']);
  });
  test('ICMP parser requires an echo timing, not a guessed duration', () {
    expect(ServerMonitor.parsePing('64 bytes: time=12.7 ms'), 13);
    expect(ServerMonitor.parsePing('64 bytes: time<1 ms'), 1);
    expect(ServerMonitor.parsePing('100% packet loss'), isNull);
    expect(ServerMonitor.parsePing('Operation not permitted'), isNull);
  });

}
