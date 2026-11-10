import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/contextual_search.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/network_context.dart';

VpnServer candidate(String name, String source, {String protocol = 'vless'}) =>
  VpnServer(id:name, name:name, country:'', countryCode:'',
    host:'$name.example', port:443, transport:'tcp',
    profile:'$protocol://$name.example:443', source:source, protocol:protocol);

void main() {
  test('ranking snapshots changing evidence and deduplicates repeated profiles', () {
    final servers = [for (var i = 0; i < 8; i++) candidate('s$i', 'source-$i')];
    final reads = <String,int>{}, exposureReads = <String,int>{};
    final plan = ContextualSearchPlanner.quick(
      baseline:[...servers, servers.first], historical:[],
      desirability:(s) {
        reads[s.id] = (reads[s.id] ?? 0) + 1;
        if (reads[s.id]! > 1) throw StateError('Evidence changed during sort');
        return int.parse(s.id.substring(1)) / 10;
      },
      sourceExposure:(s) {
        exposureReads[s.id] = (exposureReads[s.id] ?? 0) + 1;
        if (exposureReads[s.id]! > 1) throw StateError('Exposure changed during sort');
        return 0;
      },
    );
    expect(plan.map((s) => s.id), ['s7','s6','s5','s4','s3','s0']);
  });
  const wifi = NetworkContext(type:'wifi', session:'home');
  const mobile = NetworkContext(type:'mobile', session:'lte');
  test('source learning uses only real VPN verification and weak failure penalties', () {
    final good = candidate('a', 'tested-source');
    final other = candidate('b', 'unknown-source');
    final policy = SourceReliability();
    final clock = DateTime.utc(2026, 11, 9);
    expect(policy.estimate(good, wifi, now:clock).mean, .5);
    policy.observe(good, wifi, verifiedVpn:true, now:clock);
    expect(policy.estimate(good, wifi, now:clock).mean, greaterThan(.5));
    expect(policy.estimate(other, wifi, now:clock).mean, .5);
    expect(policy.estimate(good, mobile, now:clock).exposure, 0,
      reason:'A working Wi-Fi source is not proof it is reachable on LTE');
    final before = policy.estimate(good, wifi, now:clock).mean;
    policy.observe(good, wifi, verifiedVpn:false,
      attemptedButUnconfirmed:true, now:clock);
    final after = policy.estimate(good, wifi, now:clock).mean;
    expect(after, lessThan(before));
    expect(after, greaterThan(.5),
      reason:'One ambiguous timeout must not permanently blacklist a proven source');
    final aDayLater = policy.estimate(good, wifi,
      now:clock.add(const Duration(days:1)));
    final aWeekLater = policy.estimate(good, wifi,
      now:clock.add(const Duration(days:7)));
    expect(aDayLater.mean, greaterThan(.5));
    expect(aWeekLater.mean, closeTo(.5, .02));
    expect(SourceReliability.decode(policy.encode()).estimate(good, wifi,
      now:clock).mean, closeTo(after, .00001));
  });
  test('source learning changes search order in a controlled full-outcome fixture', () {
    final policy = SourceReliability();
    final clock = DateTime.utc(2026, 11, 9);
    final weak = [for (var i=0; i<3; i++) candidate('weak-$i', 'weak-provider')];
    final good = [for (var i=0; i<2; i++) candidate('good-$i', 'good-provider')];
    for (var i=0; i<12; i++) {
      policy.observe(good.first, wifi, verifiedVpn:true, now:clock);
      policy.observe(weak.first, wifi, verifiedVpn:false,
        attemptedButUnconfirmed:true, now:clock);
    }
    final baseline=[...weak, ...good];
    final proposed=ContextualSearchPlanner.quick(
      baseline:baseline, historical:[],
      desirability:(s)=>policy.estimate(s,wifi,now:clock).optimistic,
      sourceExposure:(s)=>policy.estimate(s,wifi,now:clock).exposure,
    );
    expect(baseline.first.source,'weak-provider');
    expect(proposed.first.source,'good-provider',
      reason:'Positive confirmed VPN observations, not a fake ping, drive ranking');
    final onMobile=ContextualSearchPlanner.quick(
      baseline:baseline, historical:[],
      desirability:(s)=>policy.estimate(s,mobile,now:clock).optimistic,
      sourceExposure:(s)=>policy.estimate(s,mobile,now:clock).exposure,
    );
    expect(onMobile.first.source,'weak-provider',
      reason:'Do not transfer Wi-Fi source confidence as verified LTE availability');
    expect(proposed.map((s)=>s.profile).toSet().length, proposed.length);
    // This is a synthetic full-outcome fixture, NOT an unbiased real-world
    // A/B uplift or an offline counterfactual estimate.
  });
  test('source aliases of imported VPNs update the same source model', () {
    final policy=SourceReliability();
    final saved=candidate('one','ИИ-подбор · good-provider');
    final publicPeer=candidate('two','good-provider');
    final now=DateTime.utc(2026, 11, 9);
    policy.observe(saved,wifi,verifiedVpn:true,now:now);
    expect(policy.estimate(publicPeer,wifi,now:now).mean,greaterThan(.5));
  });
  test('source reliability keeps protocols separate and bounded', () {
    final model = SourceReliability();
    final clock = DateTime.utc(2026, 11, 9);
    model.observe(candidate('one', 'same', protocol:'vless'), wifi,
      verifiedVpn:true, now:clock);
    expect(model.estimate(candidate('two', 'same',protocol:'shadowsocks'),
      wifi, now:clock).mean, .5);
    for (var n=0; n<230; n++) {
      model.observe(candidate('a$n','source-$n'), wifi,
        verifiedVpn:true, now:clock);
    }
    expect(model.learnedSources, lessThanOrEqualTo(SourceReliability.maxSources));
    expect(SourceReliability.decode({'version':1,'stats': {
      'not-a-hash': [200,0,0],
    }}).learnedSources, 0);
  });
  test('contextual plan rechecks up to two proven profiles and retains exploration', () {
    final known1=candidate('known1','history');
    final known2=candidate('known2','history');
    final known3=candidate('known3','history');
    final a=candidate('fresh-a','strong');
    final b=candidate('fresh-b','strong');
    final c=candidate('fresh-c','strong');
    final d=candidate('fresh-d','cold');
    final e=candidate('fresh-e','other');
    final f=candidate('fresh-f','other');
    final plan=ContextualSearchPlanner.quick(
      baseline:[a,b,c,d,e,f],
      historical:[known1,known2,known3],
      desirability:(s)=>s.source=='strong' ? .9 : s.source=='other' ? .6 : .52,
      sourceExposure:(s)=>s.source=='cold' ? 0 : 4,
    );
    expect(plan.length, 6);
    expect(plan.take(2), [known1,known2]);
    expect(plan.contains(known3), isFalse);
    expect(plan.contains(d), isTrue,
      reason:'Reserve a slot for a source not yet tested in the current network');
    expect(plan.map((s)=>s.profile).toSet().length, 6);
    expect(plan.where((s)=>s.source=='strong').length, lessThanOrEqualTo(2));
  });
  test('contextual plan handles one source, duplicates and empty lists', () {
    final a=candidate('same','one');
    final b=candidate('different','one');
    expect(ContextualSearchPlanner.quick(baseline:[a,a,b],historical:[],
      desirability:(_)=>.5,sourceExposure:(_)=>0).length,2);
    expect(ContextualSearchPlanner.quick(baseline:[],historical:[],
      desirability:(_)=>.5,sourceExposure:(_)=>0),isEmpty);
    expect(ContextualSearchPlanner.quick(baseline:[a,b],historical:[],
      desirability:(_)=>.5,sourceExposure:(_)=>0,limit:1).length,1);
  });
}
