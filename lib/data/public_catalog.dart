import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/profile_policy.dart';

class PublicCatalogResult {
  const PublicCatalogResult(this.servers, this.bundled, this.skipped);
  final List<VpnServer> servers;
  final bool bundled;
  final int skipped;
}

class PublicCatalog {
  static const source = 'Au1rxx/free-vpn-subscriptions';
  static const maxBytes = 2 * 1024 * 1024;
  static const urls = [
    'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/v2ray-base64.txt',
  ];
  static PublicCatalogResult parse(String text, {bool bundled = false}) {
    if (utf8.encode(text).length > maxBytes) throw const FormatException('Каталог слишком большой');
    text = text.trim();
    if (!text.contains('://')) {
      text = utf8.decode(base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))));
    }
    final servers = <VpnServer>[];
    final seen = <String>{};
    final counts = <String, int>{};
    var skipped = 0;
    for (final line in const LineSplitter().convert(text)) {
      final value = line.trim();
      if (!value.startsWith('vless://') && !value.startsWith('ss://')) continue;
      try {
        // Ignore advertising fragments when identifying duplicate profiles.
        final parsed = ProfilePolicy.parse(value.split('#').first);
        if (!publicHost(parsed.host)) { skipped++; continue; }
        final id = sha256.convert(utf8.encode(parsed.text)).toString();
        if (!seen.add(id)) continue;
        final count = counts[parsed.protocol] ?? 0;
        if (count >= 100) continue;
        counts[parsed.protocol] = count + 1;
        servers.add(VpnServer(id: 'public-$id', name: '${parsed.protocol == 'vless' ? 'VLESS' : 'Shadowsocks'} · ${parsed.host}',
          country: 'Публичный сервер', countryCode: '--', host: parsed.host, port: parsed.port,
          transport: parsed.transport, profile: parsed.text, source: source, protocol: parsed.protocol));
      } on FormatException { skipped++; }
    }
    if (servers.isEmpty) throw const FormatException('В источнике нет совместимых серверов');
    return PublicCatalogResult(servers, bundled, skipped);
  }

  static bool publicHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.localhost') || lower.endsWith('.local') || !lower.contains('.') && !lower.contains(':')) return false;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return true;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv6) {
      // Accept global unicast only; reject local and IPv4-mapped addresses.
      return (b[0] & 0xe0) == 0x20;
    }
    return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
      b[0] == 169 && b[1] == 254 || b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
      b[0] == 192 && b[1] == 168 || b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }

  Future<PublicCatalogResult> load() async {
    for (final url in urls) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        return await (() async {
          final request = await client.getUrl(Uri.parse(url));
          request.followRedirects = false;
          final response = await request.close();
          if (response.statusCode != 200) throw const FormatException('Источник недоступен');
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > maxBytes) throw const FormatException('Каталог слишком большой');
            bytes.addAll(chunk);
          }
          return parse(utf8.decode(bytes));
        })().timeout(const Duration(seconds: 12));
      } catch (_) {
        // A failed refresh must not remove the bundled fallback.
      } finally { client.close(force: true); }
    }
    return parse(await rootBundle.loadString('assets/public-proxies.txt'), bundled: true);
  }
}
