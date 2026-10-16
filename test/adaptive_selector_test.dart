import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/adaptive_selector.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/network_context.dart';
const server = VpnServer(id: 'test', name: 'test', country: '', countryCode: '', host: 'example.com',
  port: 443, transport: 'tcp', profile: 'secret-profile', source: 'test', protocol: 'vless');
void main() {
  test('preflight removes failed TCP without excluding unknown UDP', () {
    VpnServer candidate(String id, String protocol) => VpnServer(id: id, name: id,
      country: '', countryCode: '', host: 'example.com', port: 443,
      transport: protocol == 'wireguard' ? 'udp' : 'tcp', profile: id,
      source: id, protocol: protocol);
    final failed = candidate('failed', 'shadowsocks');
    final udp = candidate('udp', 'wireguard');
    final live = candidate('live', 'vless');
    final unknown = candidate('unknown', 'vless');
    final ranked = [failed, udp, unknown, live];
    final health = {
      failed.id: const HealthResult(Reachability.unreachable),
      live.id: const HealthResult(Reachability.reachable, 30),
      udp.id: const HealthResult(Reachability.notMeasured),
    };
    expect(AdaptiveSelector.shortlist(ranked, health: health).map((s) => s.id),
      ['live', 'udp', 'unknown']);
    expect(AdaptiveSelector.shortlist(ranked, limit: 1, health: health), [live]);
    expect(AdaptiveSelector.shortlist([failed], health: health), isEmpty);
  });
  test('retry preference is bounded, network-specific, persisted and does not train', () {
    const wifi = NetworkContext(type: 'wifi');
    const mobile = NetworkContext(type: 'mobile');
    final model = AdaptiveSelector();
    final now = DateTime.utc(2026, 10, 13);
    model.record(server, wifi, 'verified', speed: 200000);
    model.journal.last['time'] = now.toIso8601String();
    expect(model.recentPriority(server, wifi, now: now), 1);
    expect(model.recentPriority(server, mobile, now: now), 0);
    expect(model.recentPriority(server, wifi, now: now.add(const Duration(days: 1))), 0);
    expect(model.recentPriority(server, wifi, now: now.subtract(const Duration(seconds: 1))), 0);
    final restored = AdaptiveSelector.decode(model.encode());
    expect(restored.recentPriority(server, wifi, now: now), 1);
    restored.record(server, wifi, 'unconfirmed');
    restored.journal.last['time'] = now.toIso8601String();
    expect(restored.recentPriority(server, wifi, now: now), -1);
    expect(restored.recentPriority(server, wifi, now: now.add(const Duration(minutes: 10))), 0);
    expect(restored.recentPriority(server, const NetworkContext(type: 'wifi', ambiguous: true), now: now), 0);
    expect(restored.samples, 0);
  });
  test('measured speed preference expires, follows network and excludes failed newest results', () {
    final model = AdaptiveSelector();
    const wifi = NetworkContext(type: 'wifi');
    final now = DateTime.utc(2026, 10, 14);
    model.record(server, wifi, 'usable', speed: 95000);
    model.journal.last['time'] = now.toIso8601String();
    expect(model.recentSpeed(server, wifi, now: now), 95000);
    expect(model.recentPriority(server, wifi, now: now), 1);
    expect(model.recentSpeed(server, const NetworkContext(type: 'mobile'), now: now), 0);
    expect(model.recentSpeed(server, wifi, now: now.add(const Duration(days: 1))), 0);
    model.record(server, wifi, 'unconfirmed');
    model.journal.last['time'] = now.toIso8601String();
    expect(model.recentSpeed(server, wifi, now: now), 0);
  });
  test('quality reward ranks measured fast outcomes over measured slow outcomes', () {
    final fast = AdaptiveSelector(), slow = AdaptiveSelector();
    for (var i = 0; i < 30; i++) {
      fast.observe(server, 'wifi', 50, success: true, reward: .9);
      slow.observe(server, 'wifi', 50, success: true, reward: .3);
    }
    expect(fast.score(server, 'wifi', 50), greaterThan(slow.score(server, 'wifi', 50)));
  });
  test('uncertain outcomes are journaled without training and journal stays bounded', () {
    final model = AdaptiveSelector();
    for (var i = 0; i < 220; i++) {
      model.record(server, const NetworkContext(type: 'wifi'), 'unconfirmed');
    }
    expect(model.samples, 0);
    expect(model.journal.length, 200);
    final encoded = model.encode();
    expect(encoded, isNot(contains('secret-profile')));
    expect(encoded, isNot(contains('example.com')));
    expect(AdaptiveSelector.decode(encoded).journal.length, 200);
  });
  test('six attempts cover each protocol twice even if WireGuard ranks first', () {
    final ranked = [for (final p in ['wireguard', 'vless', 'shadowsocks'])
      for (var i = 0; i < 8; i++) VpnServer.fromJson({...server.toJson(), 'id': '$p-$i', 'protocol': p})];
    final chosen = AdaptiveSelector.shortlist(ranked);
    expect(chosen.map((s) => s.protocol), ['wireguard', 'vless', 'shadowsocks', 'wireguard', 'vless', 'shadowsocks']);
    expect(AdaptiveSelector.shortlist([]), isEmpty);
    expect(AdaptiveSelector.shortlist(ranked.take(8).toList()).length, 6);
  });
  test('online training increases confidence for success and decreases it for failure', () {
    final good = AdaptiveSelector(), bad = AdaptiveSelector();
    final features = good.features(server, 'wifi', 100);
    final initial = good.predict(features);
    for (var i = 0; i < 20; i++) {
      good.observe(server, 'wifi', 100, success: true);
      bad.observe(server, 'wifi', 100, success: false);
    }
    expect(good.predict(features), greaterThan(initial));
    expect(bad.predict(features), lessThan(initial));
    expect(good.samples, 20);
  });
  test('history is separated by network and round-trips without profile secrets', () {
    final model = AdaptiveSelector()..observe(server, 'wifi', 50, success: true);
    expect(model.features(server, 'wifi', 50)[6], greaterThan(model.features(server, 'mobile', 50)[6]));
    final saved = model.encode();
    expect(saved, isNot(contains('secret-profile')));
    expect(saved, isNot(contains('example.com')));
    final copy = AdaptiveSelector.decode(saved);
    expect(copy.score(server, 'wifi', 50), model.score(server, 'wifi', 50));
    expect(AdaptiveSelector.decode('broken').samples, 0);
  });
}

