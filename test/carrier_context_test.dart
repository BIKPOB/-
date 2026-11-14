import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_context.dart';
import 'package:quiet_vpn/core/contextual_search.dart';
import 'package:quiet_vpn/core/models.dart';

void main() {
  final networks = [
    for (final entry in {'25001':'MTS', '25002':'MegaFon', '25020':'Tele2', '25099':'Beeline'}.entries)
      NetworkContext.fromMap({'type':'mobile', 'session':'same-route',
        'operator':entry.key, 'operatorName':entry.value, 'simOperator':entry.key,
        'extended':false, 'phoneGranted':false, 'roaming':false}),
  ];
  final server = VpnServer(id:'a', name:'a', country:'', countryCode:'',
    host:'test.example', port:443, transport:'tcp', profile:'vless://test.example:443',
    source:'same-source', protocol:'vless');
  test('all four carrier labels are available in the basic startup snapshot', () {
    expect(networks.map((n) => n.carrierLabel), ['МТС','МегаФон','T2','Билайн']);
    expect(networks.map((n) => n.environmentKey).toSet(), hasLength(4));
    for (final n in networks) { expect(n.label, contains(n.carrierLabel)); }
  });
  test('confirmed source evidence stays with its carrier after persistence', () {
    final now = DateTime.utc(2026,11,14);
    for (final trained in networks) {
      final model = SourceReliability();
      model.observe(server, trained, verifiedVpn:true, now:now);
      final restored = SourceReliability.decode(model.encode());
      for (final n in networks) {
        expect(restored.estimate(server,n,now:now).exposure, n == trained ? 1 : 0);
      }
      expect(restored.estimate(server,const NetworkContext(type:'wifi'),now:now).exposure,0);
    }
  });
  test('roaming and SIM providers do not inherit host network confidence', () {
    const base = NetworkContext(type:'mobile',operator:'25099',simOperator:'25099',roaming:false);
    const virtual = NetworkContext(type:'mobile',operator:'25099',simOperator:'25001',roaming:false);
    const roaming = NetworkContext(type:'mobile',operator:'25099',simOperator:'25099',roaming:true);
    expect({base.mobileLearningScope,virtual.mobileLearningScope,roaming.mobileLearningScope},hasLength(3));
  });
  test('unknown operator stays explicit and does not pool unrelated sessions', () {
    const a = NetworkContext(type:'mobile',session:'a');
    const b = NetworkContext(type:'mobile',session:'b');
    expect(a.carrierLabel,'оператор не определён');
    expect(a.mobileLearningScope,isNot(b.mobileLearningScope));
    const wifi = NetworkContext(type:'wifi',operator:'25099',operatorName:'Beeline');
    expect(wifi.mobileOperator,isNull);
    expect(wifi.label,isNot(contains('Билайн')));
    expect(const NetworkContext(type:'mobile',operator:'bad',operatorName:'Beeline').mobileOperator,isNull);
  });
}
