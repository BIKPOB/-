import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/site_bypass.dart';
import 'package:quiet_vpn/platform/windows_config.dart';

void main() {
  test('links normalize to exact host suffixes without overbroad expansion', () {
    expect(SiteBypass.parse('https://WWW.Example.ru/a?q=1\n*.example.ru\nexample.ru.\n192.0.2.1\n2001:db8::1'),
      ['192.0.2.1', '2001:db8::1', 'example.ru', 'www.example.ru']);
    for (final input in ['https://user:password@example.ru', 'regexp:.*', '*.ru', 'ru', 'https://bad_host.ru', 'file:///tmp/file', 'example.ru example.com']) {
      expect(() => SiteBypass.parse(input), throwsFormatException, reason: input);
    }
  });
  test('exceptions keep default proxy and DNS protected, including IPv6', () {
    const profile = 'ss://aes-128-gcm:secret@example.com:443';
    final config = WindowsConfig.xray(profile, '203.0.113.1', bypassSites: ['example.ru', '2001:db8::1']);
    expect((config['outbounds'] as List).first['tag'], 'proxy');
    final rules = config['routing']['rules'] as List;
    expect(rules.first['inboundTag'], ['dns-query']);
    expect(rules.first['outboundTag'], 'proxy');
    expect(rules[1]['outboundTag'], 'dns');
    expect(rules[2]['domain'], ['domain:example.ru']);
    expect(rules[2]['inboundTag'], ['tun']);
    expect(rules[3]['ip'], ['2001:db8::1']);
    expect(config['inbounds'][0]['sniffing']['routeOnly'], true);
    final empty = WindowsConfig.xray(profile, '203.0.113.1');
    expect((empty['outbounds'] as List).any((o) => o['protocol'] == 'freedom'), false);
  });
}
