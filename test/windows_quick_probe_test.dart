import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/platform/windows_probe.dart';

void main() {
  test('quick Windows check races controls and keeps real HTTPS without speed', () async {
    final stalled=Completer<Map<String,dynamic>>();
    final started=<String>[];
    final probe=WindowsProbe(controlProbe:(address,host) async {
      expect(address,'10.0.0.2'); started.add(host);
      if(host=='www.gstatic.com') return stalled.future;
      return {'delay':40,'latencyMs':40,'httpsVerified':true,'quality':false};
    });
    final result=await probe.measure('10.0.0.2',quick:true).timeout(const Duration(seconds:1));
    expect(started.length,2);
    expect(result['httpsVerified'],isTrue);
    expect(result['bytesPerSecond'],isNull);
    expect(result['quality'],isFalse);
    probe.cancel(); stalled.complete({'delay':-1});
  });
  test('first failed control cannot override later successful HTTPS', () async {
    final probe=WindowsProbe(controlProbe:(_,host) async {
      if(host=='www.gstatic.com') throw StateError('blocked fixture');
      await Future<void>.delayed(const Duration(milliseconds:10));
      return {'delay':55,'latencyMs':55,'httpsVerified':true,'quality':false};
    });
    expect((await probe.measure('10.0.0.2',quick:true))['delay'],55);
    probe.cancel();
  });
  test('unverified and failed controls never produce a working result', () async {
    final probe=WindowsProbe(controlProbe:(_,host) async =>
      host=='www.gstatic.com' ? {'delay':12,'httpsVerified':false} : {'delay':-1});
    expect((await probe.measure('10.0.0.2',quick:true))['delay'],-1);
    probe.cancel();
  });
  test('cancel finishes stalled checks and rejects late confirmations', () async {
    final gate=Completer<Map<String,dynamic>>();
    final probe=WindowsProbe(controlProbe:(_,_)=>gate.future);
    final pending=probe.measure('10.0.0.2',quick:true);
    probe.cancel();
    expect((await pending.timeout(const Duration(seconds:1)))['delay'],-1);
    gate.complete({'delay':25,'httpsVerified':true});
  });
}
