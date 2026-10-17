import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/profile_policy.dart';
import 'windows_catalog_cache.dart';
import 'catalog_download.dart';

class PublicCatalogResult {
  const PublicCatalogResult(this.servers, this.bundled, this.skipped, {this.status = ''});
  final List<VpnServer> servers;
  final bool bundled;
  final int skipped;
  final String status;
}

class PublicCatalog {
  PublicCatalog({Future<PublicCatalogResult> Function()? refresh}) : _refreshOverride = refresh;
  final Future<PublicCatalogResult> Function()? _refreshOverride;
  static const _cache = MethodChannel('quietvpn/catalog-cache');
  static const source = 'Au1rxx/free-vpn-subscriptions';
  static const maxBytes = 2 * 1024 * 1024;
  static const urls = [
    'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/v2ray-base64.txt',
  ];
  static PublicCatalogResult parse(String text, {bool bundled = false, String sourceName = source}) {
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
      if (!value.startsWith('vless://') && !value.startsWith('ss://') && !value.startsWith('wireguard://')) continue;
      try {
        if (Uri.decodeFull(value).toLowerCase().contains('proton')) { skipped++; continue; }
        // Ignore advertising fragments when identifying duplicate profiles.
        final parsed = ProfilePolicy.parse(value.split('#').first);
        if (!publicHost(parsed.host)) { skipped++; continue; }
        final id = sha256.convert(utf8.encode(parsed.text)).toString();
        if (!seen.add(id)) continue;
        final count = counts[parsed.protocol] ?? 0;
        if (count >= 300) continue;
        counts[parsed.protocol] = count + 1;
        servers.add(VpnServer(id: 'public-$id', name: '${parsed.protocol == 'wireguard' ? 'WireGuard' : parsed.protocol == 'vless' ? 'VLESS' : 'Shadowsocks'} · ${parsed.host}:${parsed.port} · ${id.substring(0, 4)}',
          country: 'Публичный сервер', countryCode: '--', host: parsed.host, port: parsed.port,
          transport: parsed.transport, profile: parsed.text, source: sourceName, protocol: parsed.protocol));
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

  /// Round-robin sources; upstream 'verified' is never a local quality result.
  static List<VpnServer> diverse(List<VpnServer> input, {int? limit}) {
    final groups = <String, List<VpnServer>>{};
    for (final server in input) { groups.putIfAbsent(server.source, () => []).add(server); }
    final result = <VpnServer>[];
    final profiles = <String>{};
    var index = 0;
    while (groups.values.any((group) => index < group.length)) {
      for (final group in groups.values) {
        if (index >= group.length) continue;
        final server = group[index];
        if (!profiles.add(server.profile)) continue;
        result.add(server);
        if (limit != null && result.length >= limit) return result;
      }
      index++;
    }
    return result;
  }

  PublicCatalogResult? _recent;
  DateTime? _loadedAt;
  Future<PublicCatalogResult>? _pendingLoad;
  Future<PublicCatalogResult> load() {
    final age = _loadedAt == null ? null : DateTime.now().difference(_loadedAt!);
    if (_recent != null && age != null && !age.isNegative && age < const Duration(minutes: 5)) {
      return Future.value(_recent);
    }
    return _pendingLoad ??= (_refreshOverride?.call() ?? _refresh()).then((result) {
      _recent = result; _loadedAt = DateTime.now(); return result;
    }).whenComplete(() { _pendingLoad = null; });
  }
  Future<PublicCatalogResult> _refresh() async {
    final parts = await Future.wait([
      _loadSource('https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS_mobile.txt',
        null, 'igareck RU Mobile-150', ''),
      _loadSource('https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS.txt',
        null, 'igareck RU VLESS', ''),
      _loadSource('https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_SS_WEAK_DPI_RUS.txt',
        null, 'igareck RU Shadowsocks', ''),
      _loadSource('https://raw.githubusercontent.com/0xRadikal/Free-v2ray-Configs/main/verified/configs.txt',
        null, '0xRadikal/Free-v2ray-Configs verified', ''),
      _loadSource(urls.first, 'assets/public-proxies.txt', source, '10.10.2026'),
      _loadSource('https://raw.githubusercontent.com/NiREvil/vless/refs/heads/main/sub/v2rayng-wg.txt',
        'assets/public-wireguard.txt', 'NiREvil/vless', '11.10.2026'),
    ]);
    return PublicCatalogResult(diverse(parts.expand((p) => p.servers).toList()), parts.any((p) => p.bundled),
      parts.fold(0, (n, p) => n + p.skipped), status: parts.map((p) => p.status).join('\n'));
  }
  Future<PublicCatalogResult> _loadSource(String url, String? asset, String name, String date) async {
    var failure = 'ошибка загрузки';
    {

      try {
          final downloaded = await CatalogDownload.load(url,
            (text) { parse(text, sourceName: name); }, maxBytes: maxBytes);
          final text = downloaded.text;
          final parsed = parse(text, sourceName: name);
          try {
            if (Platform.isWindows) { await WindowsCatalogCache.save(name, text); }
            else { await _cache.invokeMethod<void>('save', {'source': name, 'text': text}); }
          } catch (_) { }
          return PublicCatalogResult(parsed.servers, false, parsed.skipped, status: '$name: обновлено · ${Uri.parse(downloaded.address).host}');
      } on TimeoutException { failure = 'таймаут загрузки';
      } on SocketException { failure = 'ошибка сети/DNS';
      } on HttpException catch (error) { failure = error.message;
      } on FormatException { failure = 'некорректная база или нет совместимых профилей';
      } catch (error) { failure = 'ошибка загрузки (${error.runtimeType})';
      }
    }
    try {
      final snapshots = Platform.isWindows ? await WindowsCatalogCache.read(name)
        : await _cache.invokeListMethod<dynamic>('read', {'source': name}) ?? [];
      for (final snapshot in snapshots) {
        try {
          final text = snapshot['text'] as String;
          final parsed = parse(text, sourceName: name);
          final updated = DateTime.fromMillisecondsSinceEpoch((snapshot['updated'] as num).toInt()).toLocal();
          return PublicCatalogResult(parsed.servers, false, parsed.skipped,
            status: '$name: сохранённое обновление ${updated.toString().substring(0, 16)} · обновить не удалось: $failure');
        } catch (_) { /* Preserve the previous validated snapshot when a candidate is invalid. */ }
      }
    } catch (_) { /* Native cache is optional on other platforms. */ }
    if (asset == null) return PublicCatalogResult([], false, 0, status: '$name: $failure; сохранённой базы нет');
    try {
      final parsed = parse(await rootBundle.loadString(asset), bundled: true, sourceName: name);
      return PublicCatalogResult(parsed.servers, true, parsed.skipped, status: '$name: резервная база $date');
    } catch (_) {
      return PublicCatalogResult([], true, 0, status: '$name: нет совместимых конфигураций');
    }
  }
}
