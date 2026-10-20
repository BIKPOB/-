import 'dart:convert';
import 'dart:io';
import 'package:quiet_vpn/platform/windows_config.dart';
import 'package:quiet_vpn/platform/candidate_host.dart';

Future<void> main(List<String> args) async {
  final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  origin.listen((request) { request.response.write('direct-route'); request.response.close(); });
  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = reservation.port; await reservation.close();
  final config = WindowsConfig.xray('ss://aes-128-gcm:fixture@example.com:443', '203.0.113.1', bypassSites: ['direct.test']);
  config['inbounds'] = [{'tag': 'tun', 'listen': '127.0.0.1', 'port': port, 'protocol': 'http', 'settings': <String,dynamic>{},
    'sniffing': config['inbounds'][0]['sniffing']}];
  config['outbounds'][0] = {'tag':'proxy', 'protocol':'blackhole', 'settings':<String,dynamic>{}};
  config['dns']['hosts'] = {'direct.test':'127.0.0.1', 'blocked.test':'127.0.0.1'};
  final p = await Process.start(args.single, ['run', '-config', 'stdin:']);
  final out = p.stdout.drain<void>(), err = p.stderr.drain<void>();
  final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
  Future<String> request(String host) async {
    final r = await client.getUrl(Uri.parse('http://$host:${origin.port}/'));
    return (await r.close()).transform(utf8.decoder).join();
  }
  try {
    p.stdin.write(jsonEncode(config)); await p.stdin.close();
    await CandidatePorts.wait(jsonEncode(config));
    if (await request('direct.test').timeout(const Duration(seconds: 5)) != 'direct-route') throw StateError('Excluded domain failed');
    var blocked = false;
    try { await request('blocked.test').timeout(const Duration(seconds: 3)); } catch (_) { blocked = true; }
    if (!blocked) throw StateError('Unlisted domain escaped the proxy');
  } finally {
    client.close(force: true); await origin.close(force: true);
    p.kill(); await p.exitCode; await Future.wait([out, err]);
  }
  stdout.writeln('Explicit domain uses direct outbound; unlisted destination stays on blocked proxy.');
}
