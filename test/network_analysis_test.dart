import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_analysis.dart';
import 'package:quiet_vpn/core/network_context.dart';

void main() {
  test('probe rejects 200 portal pages and redirects at generate_204', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final analyzer = NetworkAnalyzer();
    var status = 200;
    server.listen((request) async {
      request.response.statusCode = status;
      if (status == 200) request.response.write('Not a connectivity response');
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}/generate_204');
    try {
      await expectLater(analyzer.https(endpoint), throwsA(isA<HttpException>()));
      status = 302;
      await expectLater(analyzer.https(endpoint), throwsA(isA<HttpException>()));
      status = 204;
      expect(await analyzer.https(endpoint), greaterThan(0));
      status = 200;
      expect(await analyzer.https(endpoint.replace(path:'/trace')), greaterThan(0));
      status = 204;
      await expectLater(analyzer.https(endpoint.replace(path:'/download'), bytes:1),
          throwsA(isA<HttpException>()));
    } finally {
      analyzer.cancel();
      await server.close(force:true);
    }
  });
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
