import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import '../core/models.dart';
import '../core/profile_policy.dart';

class CatalogResult {
  const CatalogResult(this.servers, this.fetchedAt, {this.cached = false, this.rejected = 0});
  final List<VpnServer> servers;
  final DateTime fetchedAt;
  final bool cached;
  final int rejected;
}

class CatalogRepository {
  CatalogRepository(this.cacheFile, {Uri? endpoint})
    : endpoint = endpoint ?? Uri.parse('https://www.vpngate.net/api/iphone/');
  final File cacheFile;
  final Uri endpoint;
  HttpClient? _http;
  static const maxBody = 12 * 1024 * 1024;

  Future<CatalogResult> load({bool force = false}) async {
    if (!force) {
      final cached = await _readCache();
      if (cached != null && DateTime.now().difference(cached.fetchedAt) < const Duration(minutes: 15)) return cached;
    }
    try {
      if (endpoint.scheme != 'https') throw const FormatException('Каталог должен использовать HTTPS');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      _http = client;
      try {
        final payload = await _fetchWithFallback().timeout(const Duration(seconds: 25), onTimeout: () {
          client.close(force: true); throw const SocketException('Catalog timeout');
        });
        final body = payload.$1;
        final parsed = await Isolate.run(() => parseCsv(body));
        final result = CatalogResult(parsed.servers, payload.$2, rejected: parsed.rejected);
        if (result.servers.isEmpty) throw const FormatException('Каталог не содержит совместимых профилей');
        // Cache only public VPN Gate profiles. Private imports use secure storage.
        try {
          await cacheFile.parent.create(recursive: true);
          final temp = File('${cacheFile.path}.tmp');
          await temp.writeAsString(jsonEncode({'fetchedAt': result.fetchedAt.toIso8601String(),
            'csv': body}), flush: true);
          if (await cacheFile.exists()) await cacheFile.delete();
          await temp.rename(cacheFile.path);
        } on FileSystemException { /* Online results remain usable without cache. */ }
        return result;
      } finally { client.close(force: true); _http = null; }
    } catch (_) {
      final cached = await _readCache();
      if (cached != null && DateTime.now().difference(cached.fetchedAt) < const Duration(hours: 24)) return cached;
      rethrow;
    }
  }

  Future<(String, DateTime)> _fetchWithFallback() async {
    final sources = [endpoint];
    if (endpoint.host == 'www.vpngate.net') {
      sources.add(Uri.parse('https://raw.githubusercontent.com/BIKPOB/-/main/catalog/vpngate.json'));
    }
    final errors = <String>[];
    for (final source in sources) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      try { return await _fetch(client, source).timeout(const Duration(seconds: 11)); }
      catch (error) { errors.add('${source.host}: ${error is HttpException ? error.message : error is FormatException ? error.message : 'нет ответа сети'}'); }
      finally { client.close(force: true); }
    }
    throw FormatException('Источники базы недоступны. ${errors.join('; ')}');
  }

  Future<(String, DateTime)> _fetch(HttpClient client, Uri source) async {
    final req = await client.getUrl(source);
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('Catalog HTTP ${res.statusCode}');
    final chunks = <int>[];
    await for (final chunk in res) {
      if (chunks.length + chunk.length > maxBody) throw const FormatException('Каталог слишком большой');
      chunks.addAll(chunk);
    }
    final stamp = int.tryParse(res.headers.value('x-catalog-fetched-at') ?? '');
    var fetched = stamp == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(stamp * 1000);
    var body = utf8.decode(chunks);
    if (body.trimLeft().startsWith('{')) {
      final snapshot = jsonDecode(body) as Map<String, dynamic>;
      fetched = DateTime.parse(snapshot['fetchedAt'] as String);
      body = snapshot['csv'] as String;
    }
    final age = DateTime.now().difference(fetched);
    if (age > const Duration(hours: 24) || age < const Duration(minutes: -5)) {
      throw const FormatException('Каталог просрочен или содержит неверную дату');
    }
    return (body, fetched);
  }

  Future<CatalogResult?> _readCache() async {
    try {
      if (!await cacheFile.exists() || await cacheFile.length() > maxBody * 2) return null;
      final data = jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
      final date = DateTime.parse(data['fetchedAt'] as String);
      if (date.isAfter(DateTime.now().add(const Duration(minutes: 5)))) return null;
      final body = data['csv'] as String;
      final result = await Isolate.run(() => parseCsv(body));
      if (result.servers.isEmpty) return null;
      return CatalogResult(result.servers, date, cached: true, rejected: result.rejected);
    } catch (_) { return null; }
  }
  Future<int> cacheSize() async => await cacheFile.exists() ? await cacheFile.length() : 0;
  Future<void> clearCache() async {
    if (await cacheFile.exists()) await cacheFile.delete();
    final temporary = File('${cacheFile.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
  }
  void dispose() => _http?.close(force: true);

  static CatalogResult parseCsv(String body) {
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    final start = lines.indexWhere((l) => l.startsWith('#HostName,'));
    if (start < 0) throw const FormatException('Неверный формат VPN Gate');
    final end = lines.indexWhere((l) => l.trim() == '*', start + 1);
    final csv = [lines[start].substring(1), ...lines.sublist(start + 1, end < 0 ? lines.length : end)].join('\n');
    final records = const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(csv);
    final header = records.first.map((v) => v.toString()).toList();
    for (final key in ['HostName', 'IP', 'CountryLong', 'CountryShort', 'OpenVPN_ConfigData_Base64']) {
      if (!header.contains(key)) throw const FormatException('Отсутствуют поля каталога');
    }
    final servers = <String, VpnServer>{};
    var rejected = 0;
    for (final row in records.skip(1).take(5000)) {
      try {
        if (row.length != header.length) throw const FormatException('CSV row');
        final j = {for (var i = 0; i < header.length; i++) header[i]: row[i].toString()};
        final raw = j['OpenVPN_ConfigData_Base64']!;
        if (raw.length > ProfilePolicy.maxBytes * 2) throw const FormatException('Profile size');
        final profile = ProfilePolicy.parse(utf8.decode(base64Decode(raw)));
        // Public catalog must not make the client probe arbitrary private LANs.
        final ip = InternetAddress.tryParse(j['IP']!);
        if (ip == null || !isPublicIp(ip) || InternetAddress.tryParse(profile.host)?.address != ip.address) {
          throw const FormatException('Remote does not match the public catalog IP');
        }
        final id = sha256.convert(utf8.encode('vpngate:${ip.address}:${profile.port}:${profile.transport}')).toString().substring(0, 24);
        final country = j['CountryLong']!;
        final code = j['CountryShort']!;
        if (country.length > 80 || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) throw const FormatException('Country');
        servers[id] = VpnServer(id: id, name: j['HostName']!.substring(0, j['HostName']!.length > 100 ? 100 : j['HostName']!.length),
          country: country, countryCode: code, host: profile.host, port: profile.port,
          transport: profile.transport, profile: profile.text, source: 'VPN Gate',
          score: int.tryParse(j['Score'] ?? '') ?? 0);
      } catch (_) { rejected++; }
    }
    return CatalogResult(servers.values.toList()..sort((a, b) => b.score.compareTo(a.score)), DateTime.now(), rejected: rejected);
  }

  static bool isPublicIp(InternetAddress ip) {
    if (ip.type != InternetAddressType.IPv4) return false; // Public feed v1: IPv4 only.
    final b = ip.rawAddress;
    return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
      (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
      (b[0] == 192 && b[1] == 0) || (b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51)) ||
      (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }
}
