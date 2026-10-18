import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:quiet_vpn/core/candidate_lab.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/network_analysis.dart';
import 'package:quiet_vpn/core/network_context.dart';
import 'package:quiet_vpn/core/selection_policy.dart';
import 'package:quiet_vpn/core/search_rotation.dart';
import 'package:quiet_vpn/platform/candidate_host.dart';

void check(bool value,String message) {if(!value) throw StateError(message);}
VpnServer fixture(int id) => VpnServer(id:'$id',name:'fixture',country:'test',countryCode:'--',
  host:'node$id.example',port:443,transport:'tcp',source:'test',protocol:'vless',
  profile:'vless://12345678-1234-1234-1234-123456789abc@node$id.example:443?security=tls&sni=verified.example');
class Host implements CandidateHost {
  final ports=<int,int>{};int stops=0;bool running=false,badFirst=false;
  @override Future<String> resolveCandidate(String host) async => '203.0.113.${host.contains('1')?1:host.contains('2')?2:3}';
  @override Future<void> startCandidates(String configuration) async {
    final c=jsonDecode(configuration) as Map;
    final ins=c['inbounds'] as List,outs=c['outbounds'] as List;
    if(badFirst && outs.any((o)=>o['protocol']=='vless' && o['settings']['vnext'][0]['address']=='203.0.113.1')) throw StateError('Fixture rejection');
    for(var i=0;i<ins.length;i++) {
      check(ins[i]['listen']=='127.0.0.1' && ins[i]['protocol']=='http','Non-loopback or TUN inbound');
      check(outs[i]['streamSettings']['tlsSettings']['serverName']=='verified.example','SNI lost');
      final endpoint=outs[i]['settings']['vnext'][0]['address'] as String;
      ports[ins[i]['port'] as int]=int.parse(endpoint.split('.').last);
      check(c['routing']['rules'][i]['outboundTag']==outs[i]['tag'],'Candidate routing crossed');
    }
    running=true;
  }
  @override Future<void> stopCandidates() async {stops++;running=false;}
}
class Probe extends NetworkAnalyzer {
  Probe(this.host);final Host host;
  int handshakes=0,maxHandshakes=0,downloads=0,maxDownloads=0;
  final rounds=<int,int>{};
  @override Future<int> https(Uri uri,{int? proxyPort,int bytes=0,int maxBytes=4096,
      Duration timeout=const Duration(seconds:6)}) async {
    check(host.running,'Probe after core teardown');
    if(bytes==0) {
      handshakes++;if(handshakes>maxHandshakes)maxHandshakes=handshakes;
      await Future<void>.delayed(const Duration(milliseconds:10));handshakes--;return 10;
    }
    downloads++;if(downloads>maxDownloads)maxDownloads=downloads;
    await Future<void>.delayed(const Duration(milliseconds:5));downloads--;
    final node=host.ports[proxyPort]!,round=rounds.update(node,(n)=>n+1,ifAbsent:()=>0);
    return node==1 ? (round==1?3000000:3000) : node==2 ? 1000000 : 500000;
  }
}
class GateProbe extends NetworkAnalyzer {
  final entered=Completer<void>(),gate=Completer<int>();
  @override Future<int> https(Uri uri,{int? proxyPort,int bytes=0,int maxBytes=4096,
    Duration timeout=const Duration(seconds:6)}) {
    if(!entered.isCompleted) entered.complete();return gate.future;
  }
  @override void cancel() {if(!gate.isCompleted)gate.completeError(StateError('Cancelled fixture'));super.cancel();}
}
// A real TCP proxy that accepts CONNECT but never completes TLS. Closing
// HttpClient alone used to leave the request future pending indefinitely.
class StalledProxyHost implements CandidateHost {
  final listeners=<ServerSocket>[];
  final peers=<Socket>[];
  final connected=Completer<void>();
  final bool acknowledge;
  StalledProxyHost({this.acknowledge=true});
  @override Future<String> resolveCandidate(String host) async => '203.0.113.1';
  @override Future<void> startCandidates(String configuration) async {
    for(final entry in jsonDecode(configuration)['inbounds'] as List) {
      final listener=await ServerSocket.bind(InternetAddress.loopbackIPv4,entry['port'] as int);
      listeners.add(listener);
      listener.listen((peer) {
        peers.add(peer);var sent=false;
        peer.listen((_) {
          if(!sent) {
            sent=true;
            if(acknowledge) peer.write('HTTP/1.1 200 Connection established\r\n\r\n');
            if(!connected.isCompleted) connected.complete();
          }
        },onError:(Object _){});
      });
    }
  }
  @override Future<void> stopCandidates() async {
    for(final peer in peers.toList()) {peer.destroy();}peers.clear();
    for(final listener in listeners.toList()) {await listener.close();}listeners.clear();
  }
}
class ShortDeadlineProbe extends NetworkAnalyzer {
  @override Future<int> https(Uri uri,{int? proxyPort,int bytes=0,int maxBytes=4096,
    Duration timeout=const Duration(seconds:6)}) => super.https(uri,proxyPort:proxyPort,
      bytes:bytes,maxBytes:maxBytes,timeout:const Duration(milliseconds:150));
}
Future<void> stalledTlsRegression() async {
  for(final acknowledge in [false,true]) {
    final host=StalledProxyHost(acknowledge:acknowledge);
    final reports=<CandidateResult>[],statuses=<String>[];
    final results=await CandidateLab(host,probe:ShortDeadlineProbe()).run(
      [for(var i=1;i<=6;i++) fixture(i)],deep:false,metered:true,
      routeValid:() async=>true,status:statuses.add,onResult:reports.add)
      .timeout(const Duration(seconds:5));
    check(results.length==6 && results.every((r)=>!r.usable),'Stalled CONNECT/TLS skipped candidates');
    check(reports.length==6 && statuses.where((s)=>s.startsWith('Параллельная')).length==2,
      'No live results or no advancement to the next group');
    check(host.listeners.isEmpty && host.peers.isEmpty,'Stalled proxy resources survived cleanup');
  }
  final host=StalledProxyHost(),probe=NetworkAnalyzer();
  final lab=CandidateLab(host,probe:probe);
  final pending=lab.run([fixture(1)],deep:false,metered:true,routeValid:()async=>true,status:(_){});
  await host.connected.future.timeout(const Duration(seconds:2));
  // Allow CONNECT to upgrade into the intentionally stalled TLS handshake.
  await Future<void>.delayed(const Duration(milliseconds:30));
  await lab.cancel().timeout(const Duration(seconds:2));
  check((await pending).isEmpty && host.listeners.isEmpty,'Cancel left TLS search pending');
}
class RecoveringSpeedProbe extends NetworkAnalyzer {
  RecoveringSpeedProbe({this.failures=3});
  final int failures;
  int attempts=0;
  @override Future<int> https(Uri uri,{int? proxyPort,int bytes=0,int maxBytes=4096,
      Duration timeout=const Duration(seconds:6)}) async {
    if(bytes==0) return 10;
    attempts++;
    if(attempts<=failures) throw const SocketException('fixture download failed');
    return 2000000;
  }
}
Future<void> rotationIntegration() async {
  final data=<String,dynamic>{};
  final rotation=SearchRotation(data), host=Host(), probe=GateProbe();
  final candidates=[for(var i=1;i<=30;i++) fixture(i)];
  final lab=CandidateLab(host,probe:probe);
  final now=DateTime.now();
  final pending=lab.run(candidates,deep:false,metered:true,
    routeValid:()async=>true,status:(_){},onAttempt:(group)async {
      rotation.mark('wifi',group.map((s)=>s.id),now);
    });
  await probe.entered.future;
  await lab.cancel();await pending;
  final next=SearchRotation(data).order(candidates,'wifi',(s)=>s.id,now);
  check(next.first.id=='4','Cancelled search consumed unstarted groups or lost progress');
  check(next.take(24).last.id=='27','Rotation did not advance beyond the shortlist');
  final speedHost=Host(), speedProbe=RecoveringSpeedProbe();
  final results=await CandidateLab(speedHost,probe:speedProbe).run(
    candidates.take(6).toList(),deep:false,metered:true,target:1000000,
    routeValid:()async=>true,status:(_){});
  check(results.any((r)=>r.usable),'Three failed downloads hid later working candidates');
  check(speedProbe.attempts<=6,'Fast search exceeded its original transfer budget');
  for(final deep in [false,true]) {
    final probe=RecoveringSpeedProbe(failures:0);
    final results=await CandidateLab(Host(),probe:probe).run(candidates,
      deep:deep,metered:true,target:1000000,routeValid:()async=>true,status:(_){});
    check(results.where((r)=>r.usable).length==(deep?3:2),
      'Search stopped before comparing the required qualified candidates');
  }
}
Future<void> main() async {
  await rotationIntegration();
  await stalledTlsRegression();
  final candidates=[fixture(1),fixture(2),fixture(3)];
  final host=Host(),bad=Host()..badFirst=true;
  final probe=Probe(host);
  final results=await CandidateLab(host,probe:probe).run(candidates,deep:true,metered:true,
    target:2000000,routeValid:() async=>true,status:(_){});
  check(probe.maxHandshakes==3,'Handshakes did not run concurrently');
  check(probe.maxDownloads==1,'Speed tests competed for bandwidth');
  check(results.first.server.id=='2' && results.first.speed==1000000,'Burst speed beat stable minimum');
  check(!host.running && host.stops>0,'Core left running');
  final recovered=await CandidateLab(bad,probe:Probe(bad)).run(candidates,deep:true,metered:true,
    target:2000000,routeValid:() async=>true,status:(_){});
  check(recovered.where((r)=>r.usable).length==2,'One invalid profile vetoed valid peers');
  for(final changeRoute in [false,true]) {
    final h=Host(),gate=GateProbe();var valid=true;
    final lab=CandidateLab(h,probe:gate);
    final pending=lab.run(candidates,deep:false,metered:true,routeValid:() async=>valid,status:(_){});
    await gate.entered.future;
    if(changeRoute) {valid=false;} else {await lab.cancel();}
    final stopped=await pending.timeout(const Duration(seconds:3));
    check(stopped.isEmpty && !h.running,'Cancelled or changed-route samples accepted');
  }
  const a=NetworkContext(type:'wifi',session:'boot1:1',historyKey:'local-network-a');
  const b=NetworkContext(type:'wifi',session:'boot2:2',historyKey:'local-network-a');
  check(a.environmentKey==b.environmentKey && !a.sameConnection(b),'History and live cancellation identities mixed');
  final report=NetworkAnalysis('private-local-key',DateTime.now(),20,[100,150,110],true,false,[]);
  final unreliable=NetworkAnalysis('test',DateTime.now(),null,[400,1500,500],true,false,[]);
  check(unreliable.preferLiteralEndpoint && unreliable.extraSpeedSample && unreliable.candidateTimeout.inSeconds==8,
    'Direct network results did not adjust probe policy');
  check(report.jitterMs==50 && !report.report.contains('private-local-key'),'Profile privacy/jitter failed');
  final policy=SelectionPolicy.parse(File('assets/connection-policy.json').readAsStringSync());
  check(policy.fastCandidates==12 && policy.deepSeconds==100,'Bundled policy mismatch');
  var rejected=false;
  try {SelectionPolicy.parse('{"schema":1,"region":"RU","version":1,"fastCandidates":10000}');}catch(_){rejected=true;}
  check(rejected,'Unbounded remote policy accepted');
  stdout.writeln('Network lab: parallel handshakes, serialized speed, stable minimum, isolation, cancel, route change, privacy and policy bounds passed.');
}
