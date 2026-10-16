import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/data/catalog_download.dart';
import 'package:quiet_vpn/data/public_catalog.dart';
void main() {
  const profile = 'vless://12345678-1234-1234-1234-123456789abc@8.8.8.8:443';
  void validate(String text) { PublicCatalog.parse(text); }
  test('blocked GitHub does not prevent publisher mirror from loading', () async {
    final value = await CatalogDownload.firstValid(['github', 'mirror'], validate,
      fetch: (address) async { if (address == 'github') throw const SocketException('blocked'); return profile; });
    expect(value.address, 'mirror');
    expect(value.text, profile);
  });
  test('fast HTML response cannot beat a valid slower catalog', () async {
    final valid = Completer<String>();
    final result = CatalogDownload.firstValid(['bad', 'good'], validate,
      fetch: (address) async => address == 'bad' ? '<html>Access denied</html>' : await valid.future);
    valid.complete(profile);
    expect((await result).address, 'good');
  });
  test('all failures resolve as an error for cache fallback', () async {
    await expectLater(CatalogDownload.firstValid(['a', 'b'], validate,
      fetch: (_) async => throw const SocketException('unavailable')), throwsA(isA<SocketException>()));
  });
  test('mirrors apply only to exact igareck repository', () {
    const original = 'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS.txt';
    expect(CatalogDownload.addresses(original), [original.replaceFirst('raw.githubusercontent.com', 'raw.githack.com'), original]);
    expect(CatalogDownload.addresses('https://example.com/file.txt'), ['https://example.com/file.txt']);
  });
}
