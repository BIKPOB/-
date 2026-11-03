import 'dart:convert';
import 'dart:io';
import 'package:quiet_vpn/core/network_analysis.dart';
import 'package:quiet_vpn/platform/candidate_host.dart';
Future<void> main(List<String> args) async {
  final probe=NetworkAnalyzer();
  final socket=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);
  final port=socket.port;await socket.close();
  final config={'log':{'loglevel':'warning'},'inbounds':[
    {'listen':'127.0.0.1','port':port,'protocol':'http','settings':<String,dynamic>{}}],
    'outbounds':[{'protocol':'freedom','settings':<String,dynamic>{},
      'streamSettings':{'sockopt':{'interface':args[1]}}}]};
  final process=await Process.start(args[0],['run','-config','stdin:']);
  final out=process.stdout.drain<void>(),err=process.stderr.drain<void>();
  try {
    process.stdin.write(jsonEncode(config));await process.stdin.close();
    await CandidatePorts.wait(jsonEncode(config));
    var blocked=false;
    try {await probe.https(Uri.parse('https://1.1.1.1/cdn-cgi/trace'),timeout:const Duration(seconds:3));}
    catch (_) {blocked=true;}
    if(!blocked) throw StateError('Blackhole TUN did not isolate unbound traffic');
    await probe.https(Uri.parse('https://1.1.1.1/cdn-cgi/trace'),proxyPort:port,timeout:const Duration(seconds:10));
  } finally {probe.cancel();process.kill();await process.exitCode;await Future.wait([out,err]);}
  stdout.writeln('Reserve HTTPS bypassed blackhole TUN only via the physical interface.');
}
