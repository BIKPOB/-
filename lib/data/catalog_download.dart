import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Race only publisher-listed mirrors; an HTTP 200 is not enough to win.
class CatalogDownload {
  static List<String> addresses(String original) => original.startsWith(
    'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/')
      ? [original.replaceFirst('raw.githubusercontent.com', 'raw.githack.com'), original]
      : [original];

  static Future<({String text, String address})> firstValid(List<String> addresses,
      void Function(String) validate, {required Future<String> Function(String) fetch}) {
    final result = Completer<({String text, String address})>();
    var pending = addresses.length;
    if (pending == 0) return Future.error(const HttpException('Нет адресов источника'));
    for (final address in addresses) {
      () async {
        try {
          final text = await fetch(address);
          if (result.isCompleted) return;
          validate(text);
          result.complete((text: text, address: address));
        } catch (error, stack) {
          if (--pending == 0 && !result.isCompleted) result.completeError(error, stack);
        }
      }();
    }
    return result.future;
  }

  static Future<({String text, String address})> load(String original,
      void Function(String) validate, {required int maxBytes}) async {
    final clients = <HttpClient>[];
    try {
      return await firstValid(addresses(original), validate, fetch: (address) async {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        clients.add(client);
        try {
          return await (() async {
            final request = await client.getUrl(Uri.parse(address));
            request.followRedirects = false;
            final response = await request.close();
            if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
            final bytes = <int>[];
            await for (final chunk in response) {
              if (bytes.length + chunk.length > maxBytes) throw const FormatException('Каталог слишком большой');
              bytes.addAll(chunk);
            }
            return utf8.decode(bytes);
          })().timeout(const Duration(seconds: 12));
        } finally { client.close(force: true); }
      });
    } finally {
      // Close the loser too: no hidden download after a valid mirror has won.
      for (final client in clients) { client.close(force: true); }
    }
  }
}
