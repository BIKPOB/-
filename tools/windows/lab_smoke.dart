import 'dart:convert';
import 'dart:io';
import 'package:quiet_vpn/core/candidate_lab.dart';
import 'package:quiet_vpn/core/network_analysis.dart';

Future<void> main(List<String> args) async {
  final ports=<int>[];
  for(var i=0;i<3;i++) {final s=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);ports.add(s.port);await s.close();}
  final config=CandidateConfig.build([for(final port in ports)
    (profile:'ss://aes-128-gcm:fixture@example.com:443',endpoint:'203.0.113.1',port:port)]);
  // Direct outbounds are a CI fixture for the proxy path, never a VPN profile.
  config['outbounds']=[for(var i=0;i<3;i++) {'tag':'candidate-$i','protocol':'freedom','settings':<String,dynamic>{}}];
  final p=await Process.start(args.single,['run','-config','stdin:']);
  final out=p.stdout.drain<void>(),err=p.stderr.drain<void>();
  final probe=NetworkAnalyzer();
  try {
    p.stdin.write(jsonEncode(config));await p.stdin.close();
    await Future<void>.delayed(const Duration(seconds:1));
    final timings=await Future.wait([for(final port in ports)
      probe.https(Uri.parse('https://cp.cloudflare.com/generate_204'),proxyPort:port)]);
    if(timings.any((n)=>n<=0)) throw StateError('Proxy HTTPS not verified');
    final speed=await probe.https(Uri.parse('https://speed.cloudflare.com/__down?bytes=524288'),
      proxyPort:ports.first,bytes:524288,maxBytes:524288,timeout:const Duration(seconds:10));
    if(speed<=0) throw StateError('Proxy download not verified');
  } finally {probe.cancel();p.kill();await p.exitCode;await Future.wait([out,err]);}
  for(final port in ports) {
    final s=await ServerSocket.bind(InternetAddress.loopbackIPv4,port);await s.close();
  }
  stdout.writeln('Three isolated HTTP proxies verified HTTPS, bounded download and port cleanup with pinned Xray.');
}
