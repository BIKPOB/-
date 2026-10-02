import 'dart:io';
import 'package:flutter/foundation.dart';

/// Downloads only the pinned official Windows installer; never executes profiles.
class RuntimeManager extends ChangeNotifier {
  RuntimeManager(this.cacheDirectory);
  final Directory cacheDirectory;
  bool busy = false, installed = false;
  int downloaded = 0, total = 0, cacheBytes = 0;
  String? message;
  bool _disposed = false;
  HttpClient? _client;
  static const installerName = 'OpenVPN-2.7.7-I001-amd64.msi';
  static final installerUri = Uri.parse('https://swupdate.openvpn.net/community/releases/$installerName');
  File get installer => File('${cacheDirectory.path}/$installerName');
  void _notify() { if (!_disposed) notifyListeners(); }
  Future<void> refresh() async {
    if (!Platform.isWindows) { installed = Platform.isAndroid; _notify(); return; }
    final root = Platform.environment['ProgramW6432'] ?? Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    installed = await File('$root/OpenVPN/bin/openvpn.exe').exists();
    cacheBytes = await installer.exists() ? await installer.length() : 0;
    _notify();
  }
  Future<void> clearCache() async {
    if (busy) return;
    if (await installer.exists()) await installer.delete();
    final part = File('${installer.path}.part');
    if (await part.exists()) await part.delete();
    await refresh();
  }
  Future<void> downloadAndInstall() async {
    if (!Platform.isWindows || busy) return;
    busy = true; downloaded = 0; total = 0; message = 'Загрузка официального OpenVPN…'; _notify();
    final part = File('${installer.path}.part');
    try {
      await cacheDirectory.create(recursive: true);
      if (!await installer.exists()) {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
        _client = client;
        try {
          await (() async {
            var uri = installerUri;
            HttpClientResponse? response;
            for (var redirect = 0; redirect < 4; redirect++) {
              if (uri.scheme != 'https' || !{'swupdate.openvpn.net', 'swupdate.openvpn.org'}.contains(uri.host)) {
                throw const FormatException('Недопустимый источник установщика');
              }
              final request = await client.getUrl(uri); request.followRedirects = false;
              response = await request.close();
              if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
              final location = response.headers.value('location');
              await response.drain<void>();
              if (location == null) throw const HttpException('Нет адреса загрузки');
              uri = uri.resolve(location); response = null;
            }
            if (response == null || response.statusCode != 200) throw const HttpException('Загрузка недоступна');
            total = response.contentLength;
            if (total > 64 * 1024 * 1024) throw const FormatException('Установщик слишком большой');
            final sink = part.openWrite();
            var lastNotice = DateTime.now();
            try {
              await for (final chunk in response) {
                downloaded += chunk.length;
                if (downloaded > 64 * 1024 * 1024) throw const FormatException('Лимит загрузки превышен');
                sink.add(chunk);
                if (DateTime.now().difference(lastNotice).inMilliseconds > 250) { lastNotice = DateTime.now(); _notify(); }
              }
              await sink.flush();
            } finally { await sink.close(); }
            if (downloaded == 0 || (total >= 0 && downloaded != total)) throw const HttpException('Неполная загрузка');
          })().timeout(const Duration(minutes: 3), onTimeout: () {
            client.close(force: true); throw const HttpException('Таймаут загрузки');
          });
        } finally { client.close(force: true); _client = null; }
        await part.rename(installer.path);
      }
      message = 'Проверка подписи и установка драйвера…'; _notify();
      final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final result = await Process.run('$system/System32/WindowsPowerShell/v1.0/powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command',
          r"$s=Get-AuthenticodeSignature -LiteralPath $env:QUIET_VPN_MSI; "
          r"if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch '(?i)O=OpenVPN( Inc\.)?(,|$)') { exit 42 }; "
          r'''$p=Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/i', ('"'+$env:QUIET_VPN_MSI+'"'), '/passive', '/norestart') -Wait -PassThru; exit $p.ExitCode'''],
        environment: {'QUIET_VPN_MSI': installer.path}, runInShell: false);
      if (result.exitCode == 42) {
        await installer.delete(); throw const FormatException('Подпись OpenVPN не подтверждена; файл удалён');
      }
      if (result.exitCode != 0 && result.exitCode != 3010) throw StateError('Установка не завершена (код ${result.exitCode})');
      await refresh();
      message = result.exitCode == 3010 ? 'Для драйвера нужна перезагрузка Windows' : 'OpenVPN установлен';
    } catch (error) {
      message = error is FormatException ? error.message : 'Не удалось установить OpenVPN. Проверьте сеть и права администратора.';
    } finally {
      if (await part.exists()) await part.delete();
      busy = false; await refresh(); _notify();
    }
  }
  @override void dispose() { _disposed = true; _client?.close(force: true); super.dispose(); }
}
