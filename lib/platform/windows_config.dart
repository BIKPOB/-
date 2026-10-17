import 'dart:convert';
import '../core/proxy_profile.dart';

class WindowsConfig {
  static const adapter = 'QuietVPN-Xray';
  static Map<String, dynamic> xray(String profile, String endpoint) {
    final parsed = ProxyProfile.parse(profile);
    if (parsed.protocol == 'vless' &&
        parsed.outbound['streamSettings']['security'] == 'none') {
      throw const FormatException('Windows Xray: VLESS без TLS/REALITY не поддерживается для публичных серверов');
    }
    final config = jsonDecode(parsed
      .configurationWithDiagnostics(endpointAddress: endpoint)) as Map<String, dynamic>;
    config['log'] = {'loglevel': 'info', 'access': 'none'};
    config['inbounds'] = [
      {'tag': 'tun', 'protocol': 'tun', 'settings': {
        'name': adapter, 'mtu': 1280, 'gateway': ['172.29.211.1/30', 'fd7a:115c:a1e0::1/126'],
        'dns': ['1.1.1.1', '8.8.8.8'], 'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto', 'autoSystemWfpBlockLeak': ['dns', 'misconfigtun'],
      }},
    ];
    return config;
  }
}
