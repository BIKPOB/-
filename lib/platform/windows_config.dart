import 'dart:convert';
import '../core/proxy_profile.dart';
import '../core/site_bypass.dart';

class WindowsConfig {
  static const adapter = 'QuietVPN-Xray';
  static Map<String, dynamic> xray(String profile, String endpoint, {List<String> bypassSites = const []}) {
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
    final sites = SiteBypass.parse(bypassSites.join('\n'));
    if (sites.isNotEmpty) {
      (config['inbounds'] as List).first['sniffing'] = {
        'enabled': true, 'destOverride': ['http', 'tls', 'quic'], 'routeOnly': true,
      };
      (config['outbounds'] as List).add({
        'tag': 'direct-sites', 'protocol': 'freedom', 'settings': {'domainStrategy': 'UseIP'},
      });
      final domains = sites.where((s) => !SiteBypass.isIp(s)).map((s) => 'domain:$s').toList();
      final ips = sites.where(SiteBypass.isIp).toList();
      // DNS stays on the protected resolver; exceptions affect destination traffic.
      // Existing DNS rules precede these rules. Unmatched traffic stays on proxy.
      (config['routing']['rules'] as List).addAll([
        if (domains.isNotEmpty) {'type': 'field', 'inboundTag': ['tun'],
          'domain': domains, 'outboundTag': 'direct-sites'},
        if (ips.isNotEmpty) {'type': 'field', 'inboundTag': ['tun'],
          'ip': ips, 'outboundTag': 'direct-sites'},
      ]);
    }
    return config;
  }
}
