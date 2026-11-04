import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/xray_failure.dart';
void main() {
  test('startup requires final started marker, including chunk boundaries', () {
    final log = XraySessionLog();
    log.add('Xray 26.10.1 banner\nInterface configuration failed, retrying');
    expect(log.started,false);
    log.add('\n[Warning] core: Xray 26.10.1 star');
    expect(log.started,false);
    log.add('ted\n');
    expect(log.started,true);
  });
  test('failure details survive chunks without exporting profile secrets', () {
    final log = XraySessionLog();
    log.add('Failed to start: proxy/tun: unable to set rou');
    log.add('tes > The parameter is incorrect SECRET-UUID-or-key');
    expect(log.started,false);
    expect(log.summary,contains('маршруты TUN'));
    expect(log.summary,isNot(contains('SECRET')));
  });
}
