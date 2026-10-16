import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
const fixture = '';
void main() {
  test('large sweeps cap parallel work without dropping endpoints', () async {
    var live = 0, peak = 0;
    final monitor = ServerMonitor(concurrency: 3, probe: (_) async {
      live++; if (live > peak) peak = live;
      await Future<void>.delayed(const Duration(milliseconds: 2)); live--;
      return const HealthResult(Reachability.reachable, 1);
    });
    final servers = List.generate(30, (i) => VpnServer(id: '$i', name: '', country: '',
      countryCode: '', host: '8.8.8.8', port: 443, transport: 'tcp', profile: '', source: 'test'));
    expect((await monitor.sample(servers)).length, 30);
    expect(peak, 3);
  });
  test('fast preflight checks the port and never substitutes an ICMP response', () async {
    final listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sub = listening.listen((socket) => socket.destroy());
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port; await closed.close();
    var pings = 0;
    final monitor = ServerMonitor(tcpOnly: true, ping: (_) async { pings++; return 1; });
    VpnServer node(String id, int port, String transport) => VpnServer(id: id, name: '', country: '',
      countryCode: '', host: '127.0.0.1', port: port, transport: transport, profile: '', source: 'test');
    try {
      final results = await monitor.sample([node('open', listening.port, 'tcp'),
        node('closed', closedPort, 'tcp'), node('udp', closedPort, 'udp')]);
      expect(pings, 0);
      expect(results['open']?.method, 'TCP');
      expect(results['closed']?.state, Reachability.unreachable);
      expect(results['udp']?.state, Reachability.notMeasured);
    } finally { monitor.cancel(); await sub.cancel(); await listening.close(); }
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
