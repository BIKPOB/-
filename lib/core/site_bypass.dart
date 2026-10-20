import 'dart:io';

/// Explicit destinations only; no regex, arbitrary Xray rules or URL credentials.
class SiteBypass {
  static List<String> parse(String text) {
    final result = <String>{};
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      var value = line.trim();
      if (value.isEmpty) continue;
      if (value.startsWith('*.')) value = value.substring(2);
      final literal = InternetAddress.tryParse(value);
      if (literal != null) { result.add(literal.address); continue; }
      final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
      if (uri == null || !['http', 'https'].contains(uri.scheme) ||
          uri.userInfo.isNotEmpty || uri.host.isEmpty) {
        throw const FormatException('Введите домен, IP или ссылку http/https без логина и пароля.');
      }
      var host = uri.host.toLowerCase();
      if (host.endsWith('.')) host = host.substring(0, host.length - 1);
      final ip = InternetAddress.tryParse(host);
      if (ip != null) { result.add(ip.address); continue; }
      if (host.length > 253 || !host.contains('.') || host.split('.').any((label) =>
          label.isEmpty || label.length > 63 || !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label))) {
        throw const FormatException('Нужен полный домен, например example.ru. Кириллические домены вводите в формате xn--.');
      }
      result.add(host);
    }
    if (result.length > 200) throw const FormatException('Не более 200 исключений.');
    return result.toList()..sort();
  }
  static bool isIp(String value) => InternetAddress.tryParse(value) != null;
}

abstract interface class SiteBypassHost {
  List<String> get bypassSites;
  Future<void> saveBypassSites(List<String> sites);
}
