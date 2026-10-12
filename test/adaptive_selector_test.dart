import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/adaptive_selector.dart';
import 'package:quiet_vpn/core/models.dart';
const server = VpnServer(id: 'test', name: 'test', country: '', countryCode: '', host: 'example.com',
  port: 443, transport: 'tcp', profile: 'secret-profile', source: 'test', protocol: 'vless');
void main() {
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
