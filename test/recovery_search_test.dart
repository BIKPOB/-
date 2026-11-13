import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/recovery_search.dart';
import 'package:quiet_vpn/core/network_context.dart';

VpnServer server(int n,{String? host,String type='tcp'}) {
  final address=host ?? '203.0.$n.1';
  return VpnServer(id:'$n',name:'test',country:'',countryCode:'',
    host:address,port:443,transport:type,source:'fixture',protocol:'vless',
    profile:'vless://secret-$n@$address:443?security=tls&type=$type');
}
void main() {
  const network=NetworkContext(type:'mobile',operator:'25002',historyKey:'operator-cell');
  final now=DateTime(2026,11,14);
  test('recovery explores endpoints, subnets and transports without dropping profiles', () {
    final pool=[server(1,host:'203.0.1.1'),server(2,host:'203.0.1.1'),
      server(3,host:'203.0.1.2'),server(4,type:'ws'),server(5,type:'grpc')];
    final order=RecoveryPlanner.order(pool,RecoveryHistory(null),network,now);
    expect(order.map((s)=>s.id),['1','4','5','3','2']);
    expect(order.length,pool.length);
    expect(RecoveryPlanner.order([...pool,pool.first],RecoveryHistory(null),network,now).length,pool.length);
  });
  test('only same-network recovery history gets first priority and expires', () {
    final a=server(1), b=server(2);
    final history=RecoveryHistory(null)..remember(b,network,now);
    expect(RecoveryPlanner.order([a,b],history,network,now).first,b);
    expect(history.worked(b,const NetworkContext(type:'mobile',operator:'25020',historyKey:'operator-cell'),now),isFalse);
    expect(history.worked(b,network,now.add(const Duration(days:7))),isFalse);
    expect(history.worked(b,network,now.subtract(const Duration(seconds:1))),isFalse);
    expect(RecoveryHistory(jsonDecode(jsonEncode(history.entries))).worked(b,network,now),isTrue);
    expect(jsonEncode(history.entries),isNot(contains('secret-')));
    expect(jsonEncode(history.entries),isNot(contains('203.0.')));
  });
  test('history is bounded, malformed storage ignored, ambiguous success excluded', () {
    final history=RecoveryHistory([null,42,{'time':'bad'},{'time':'2026-11-14','network':42}]);
    expect(history.entries,isEmpty);
    for(var i=0;i<150;i++) {history.remember(server(i),network,now);}
    expect(history.entries.length,128);
    history.remember(server(999),const NetworkContext(ambiguous:true),now);
    expect(history.entries.length,128);
  });
}
