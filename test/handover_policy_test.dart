import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/handover_policy.dart';
void main() {
  test('isolated failures, stale reserves, small gains and cooldown cannot switch', () {
    final p=HandoverPolicy(); final start=DateTime.utc(2026,10,18);
    bool allowed(DateTime now,{int speed=1000,DateTime? measured}) => p.canSwitch(
      profile:'reserve',speed:speed,current:300,target:800,measuredAt:measured??now,now:now);
    p.observe(300,800,start);
    expect(allowed(start),false);
    p.observe(900,800,start.add(const Duration(seconds:30)));
    expect(p.degraded(start.add(const Duration(minutes:3))),false);
    for(var i=0;i<3;i++) {p.observe(300,800,start.add(Duration(minutes:i+1)));}
    var now=start.add(const Duration(minutes:3));
    expect(allowed(now),true);
    expect(allowed(now,speed:400),false);
    expect(allowed(now,measured:start),false);
    p.beginSwitch(now);
    for(var i=0;i<3;i++) {p.observe(null,800,now.add(Duration(minutes:i)));}
    expect(allowed(now.add(const Duration(minutes:2))),false);
    now=now.add(const Duration(minutes:11));
    expect(allowed(now),true);
    p.beginSwitch(now);
    for(var i=0;i<3;i++) {p.observe(100,800,now.add(Duration(minutes:i)));}
    expect(allowed(now.add(const Duration(minutes:11))),false);
    p.failed('reserve',now);
    expect(p.eligible('reserve',now.add(const Duration(minutes:29))),false);
    expect(p.eligible('reserve',now.add(const Duration(minutes:30))),true);
    p.resetEvidence(); expect(p.degraded(now.add(const Duration(hours:2))),false);
  });
  test('failed traffic reservations cannot exceed the hourly payload cap', () {
    final p=HandoverPolicy(),now=DateTime.utc(2026,10,18);
    expect(p.reserveBytes(24*1048576,true,now),true);
    expect(p.reserveBytes(1,true,now),false);
    expect(p.reserveBytes(1,true,now.add(const Duration(hours:1))),true);
  });
}
