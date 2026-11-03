import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_analysis.dart';
import 'package:quiet_vpn/core/network_context.dart';

void main() {
  test('analysis follows current connection and stricter selection freshness', () {
    const network = NetworkContext(type:'wifi', session:'connection-a', historyKey:'same-router');
    final now = DateTime(2026,10,19);
    final sample = NetworkAnalysis(network.environmentKey,now,20,[30,35,32],true,true,[],session:network.session);
    expect(sample.fresh(network,now),true);
    expect(sample.fresh(network,now.add(const Duration(minutes:5))),false);
    expect(sample.fresh(network,now.add(const Duration(seconds:31)),maxAge:const Duration(seconds:30)),false);
    expect(sample.fresh(const NetworkContext(type:'wifi',session:'connection-b',historyKey:'same-router'),now),false);
    expect(sample.fresh(const NetworkContext(type:'wifi',session:'connection-a',historyKey:'same-router',vpnPresent:true),now),false);
    expect(NetworkAnalysis.fromJson(sample.toJson()).fresh(network,now),true);
    final legacy = sample.toJson()..remove('session');
    expect(NetworkAnalysis.fromJson(legacy).fresh(network,now),false);
  });
}
