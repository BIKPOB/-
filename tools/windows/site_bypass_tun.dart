import 'dart:convert';
import 'dart:io';
import 'package:quiet_vpn/core/network_analysis.dart';
import 'package:quiet_vpn/platform/windows_config.dart';

Future<void> main(List<String> args) async {
  if (args.first == 'config') {
    final config = WindowsConfig.xray('ss://aes-128-gcm:fixture@example.com:443', '203.0.113.1', bypassSites: ['1.1.1.1']);
    config['outbounds'][0] = {'tag':'proxy', 'protocol':'blackhole', 'settings':<String,dynamic>{}};
    await File(args[1]).writeAsString(jsonEncode(config));
    return;
  }
  final probe = NetworkAnalyzer();
  try {
    await probe.https(Uri.parse('https://1.1.1.1/cdn-cgi/trace'), timeout: const Duration(seconds: 12));
    var blocked = false;
    try { await probe.https(Uri.parse('https://8.8.8.8/'), timeout: const Duration(seconds: 3)); }
    catch (_) { blocked = true; }
    if (!blocked) throw StateError('Unlisted IP escaped blocked proxy');
  } finally { probe.cancel(); }
  stdout.writeln('Excluded IP uses direct route under active Windows TUN; unlisted IP stays blocked.');
}
