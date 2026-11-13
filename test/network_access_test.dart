import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_access.dart';
import 'package:quiet_vpn/core/network_analysis.dart';
import 'package:quiet_vpn/core/network_context.dart';

class ControlAnalyzer extends NetworkAnalyzer {
  final pending = <String, Completer<int>>{};
  final limits = <Duration>[];
  @override
  Future<int> https(Uri uri, {int? proxyPort, int bytes = 0, int maxBytes = 4096,
      Duration timeout = const Duration(seconds: 6)}) {
    expect(proxyPort, isNull);
    expect(maxBytes, 1024);
    limits.add(timeout);
    return (pending[uri.host] = Completer<int>()).future;
  }
}

void main() {
  const network = NetworkContext(type:'mobile', session:'lte-a', operator:'25002');
  final now = DateTime(2026,11,14);
  NetworkAccessSnapshot snapshot({int? external, int? domestic = 40}) =>
      NetworkAccessSnapshot(network, now, {
        for (final host in NetworkAccessMonitor.domesticHosts) host: domestic,
        for (final host in NetworkAccessMonitor.externalHosts) host: external,
      });

  test('only domestic success plus external failure suggests restrictions', () {
    expect(snapshot().possibleRestrictions, isTrue);
    expect(snapshot(domestic:null).possibleRestrictions, isFalse);
    expect(snapshot(external:80).possibleRestrictions, isFalse);
    final partial = NetworkAccessSnapshot(network, now, {
      'yandex.ru':40, 'vk.com':40, 'www.gstatic.com':70, 'cp.cloudflare.com':null,
    });
    expect(partial.external, 1);
    expect(partial.possibleRestrictions, isFalse);
  });

  test('results cannot migrate between sessions, operators, or VPN routes', () {
    final result = snapshot();
    expect(result.fresh(network, now), isTrue);
    expect(result.fresh(network, now.subtract(const Duration(seconds:1))), isFalse);
    expect(result.fresh(network, now.add(const Duration(minutes:5))), isFalse);
    expect(result.fresh(const NetworkContext(type:'mobile',session:'lte-b',operator:'25002'),now),isFalse);
    expect(result.fresh(const NetworkContext(type:'mobile',session:'lte-a',operator:'25020'),now),isFalse);
    expect(result.fresh(const NetworkContext(type:'mobile',session:'lte-a',operator:'25002',vpnPresent:true,ownVpn:true),now),isFalse);
  });

  test('restricted failures do not penalize servers but success remains evidence', () {
    final result = snapshot();
    expect(result.learningOutcome('unconfirmed',network,now),'network_limited');
    expect(result.learningOutcome('slow_or_unstable',network,now),'network_limited');
    expect(result.learningOutcome('verified',network,now),'verified');
    expect(result.learningOutcome('usable',network,now),'usable');
    expect(result.learningOutcome('unconfirmed',network,now.add(const Duration(minutes:6))),'unconfirmed');
    expect(snapshot(domestic:null).learningOutcome('unconfirmed',network,now),'unconfirmed');
  });

  test('all four controls start concurrently and retain measured durations', () async {
    final analyzer = ControlAnalyzer();
    final monitor = NetworkAccessMonitor(analyzer:analyzer);
    final pending = monitor.check(network);
    expect(analyzer.pending.length,4);
    for (final entry in analyzer.pending.entries) {
      if (NetworkAccessMonitor.domesticHosts.contains(entry.key)) {
        entry.value.complete(37);
      } else {
        entry.value.completeError(TimeoutException('fixture'));
      }
    }
    final result = await pending;
    expect(result.possibleRestrictions,isTrue);
    expect(result.results['yandex.ru'],37);
    expect(result.results['www.gstatic.com'],isNull);
    monitor.cancel();
  });

  test('deadline bounds even a stalled injected transport', () async {
    final analyzer = ControlAnalyzer();
    final monitor = NetworkAccessMonitor(analyzer:analyzer);
    final result = await monitor.check(network,timeout:const Duration(milliseconds:20));
    expect(analyzer.limits,everyElement(const Duration(milliseconds:20)));
    expect(result.domestic,0);
    expect(result.external,0);
    expect(result.possibleRestrictions,isFalse);
    monitor.cancel();
  });

  test('cancel rejects late results and unsafe routes send no requests', () async {
    final analyzer = ControlAnalyzer();
    final monitor = NetworkAccessMonitor(analyzer:analyzer);
    final pending = monitor.check(network);
    final assertion = expectLater(pending,throwsStateError);
    monitor.cancel();
    for (final value in analyzer.pending.values) { value.complete(30); }
    await assertion;
    analyzer.pending.clear();
    for (final context in [
      const NetworkContext(type:'wifi',vpnPresent:true),
      const NetworkContext(type:'wifi',ambiguous:true),
      const NetworkContext(type:'offline'),
    ]) {
      await expectLater(monitor.check(context),throwsStateError);
    }
    expect(analyzer.pending,isEmpty);
  });
}
