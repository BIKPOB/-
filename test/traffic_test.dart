import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/traffic.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/core/models.dart';

void main() {
  test('traffic uses elapsed time and rebaselines reset counters', () {
    final meter = TrafficMeter();
    meter.sample(const TrafficCounters(100, 200), Duration.zero);
    expect(meter.download, isNull);
    meter.sample(const TrafficCounters(2100, 1200), const Duration(seconds: 2));
    expect(meter.download, 1000); expect(meter.upload, 500);
    meter.sample(const TrafficCounters(1, 2), const Duration(seconds: 3));
    expect(meter.download, isNull);
    meter.sample(const TrafficCounters(1, 2), const Duration(seconds: 4));
    expect(meter.download, 0);
    meter.reset(); expect(meter.upload, isNull);
  });
  test('probe rotation reaches servers beyond first ten and skips UDP', () {
    final servers = List.generate(26, (i) => VpnServer(id: '$i', name: '', country: '',
      countryCode: '', host: '8.8.8.8', port: 443, transport: i == 0 ? 'udp' : 'tcp',
      profile: '', source: 'test'));
    final queue = ProbeQueue();
    final seen = <String>{};
    for (var i = 0; i < 3; i++) {
      final batch = queue.next(servers);
      expect(batch.length, 10); seen.addAll(batch.map((s) => s.id));
    }
    expect(seen.length, 25); expect(seen.contains('0'), isFalse);
    expect(queue.next([]), isEmpty);
    expect(queue.next(servers.take(2).toList()).single.id, '1');
  });
}
