import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class WindowsCatalogCache {
  static Future<File> _file(String source) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}\\catalog'); await dir.create(recursive: true);
    return File('${dir.path}\\${sha256.convert(utf8.encode(source))}.json');
  }
  static Future<void> save(String source, String text) async {
    final file = await _file(source);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode({'text': text, 'updated': DateTime.now().millisecondsSinceEpoch}), flush: true);
    if (await file.exists()) await file.copy('${file.path}.previous');
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
  static Future<List<dynamic>> read(String source) async {
    final file = await _file(source);
    final result = <dynamic>[];
    for (final item in [file, File('${file.path}.previous')]) {
      try { if (await item.length() <= 4 * 1024 * 1024) result.add(jsonDecode(await item.readAsString())); } catch (_) { }
    }
    return result;
  }
}
