import 'dart:convert';
import 'dart:io';

/// Reject executable hooks and external file references before native parsing.
/// Unknown directives fail closed. This intentionally supports a constrained
/// subset of self-contained OpenVPN client profiles.
class ProfilePolicy {
  static const maxBytes = 128 * 1024;
  static const _flags = {
    'client', 'nobind', 'persist-key', 'persist-tun', 'pull', 'remote-random',
    'auth-nocache', 'float', 'mute-replay-warnings',
  };
  static const _values = {
    'resolv-retry', 'cipher', 'auth', 'verb', 'mute', 'reneg-sec',
    'sndbuf', 'rcvbuf', 'tun-mtu', 'mssfix', 'connect-timeout',
    'connect-retry', 'connect-retry-max', 'keepalive', 'ping', 'ping-restart',
    'remote-cert-tls', 'verify-x509-name', 'key-direction', 'tls-version-min',
    'data-ciphers', 'data-ciphers-fallback', 'auth-retry',
  };
  static const _blocks = {'ca', 'cert', 'key', 'tls-auth', 'tls-crypt'};

  static ParsedProfile parse(String text) {
    if (utf8.encode(text).length > maxBytes || text.contains('\u0000')) {
      throw const FormatException('Профиль слишком большой или повреждён');
    }
    final lines = const LineSplitter().convert(text);
    final output = <String>[];
    final seenBlocks = <String>{};
    String? block;
    String? host;
    var port = 1194;
    var proto = 'udp';
    var hasClient = false;
    var hasCa = false;
    var authNeeded = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
      if (block != null) {
        if (line == '</$block>') { output.add(line); block = null; continue; }
        if (line.startsWith('<')) throw const FormatException('Вложенный блок');
        output.add(line);
        continue;
      }
      if (line.startsWith('<')) {
        final tag = RegExp(r'^<([a-z-]+)>$').firstMatch(line)?.group(1);
        if (tag == null || !_blocks.contains(tag) || !seenBlocks.add(tag)) {
          throw const FormatException('Недопустимый inline-блок');
        }
        block = tag;
        hasCa |= tag == 'ca';
        output.add(line);
        continue;
      }
      // No shell-style continuations, inline comments, quoted file paths or
      // --option aliases. The native engine must see the same tokenization.
      if (line.contains('\\') || line.contains('"') || line.contains("'")) {
        throw const FormatException('Неподдерживаемое экранирование');
      }
      final tokens = line.split(RegExp(r'\s+'));
      final key = tokens.first;
      if (key == 'remote') {
        if (host != null || tokens.length < 2 || tokens.length > 3) {
          throw const FormatException('Нужен один remote без дополнительных параметров');
        }
        host = tokens[1];
        if (tokens.length == 3) port = int.tryParse(tokens[2]) ?? 0;
        if (!validHost(host) || port < 1 || port > 65535) {
          throw const FormatException('Некорректный адрес remote');
        }
      } else if (key == 'proto') {
        if (tokens.length != 2 || !{'udp', 'udp4', 'udp6', 'tcp', 'tcp-client', 'tcp4-client', 'tcp6-client'}.contains(tokens[1])) {
          throw const FormatException('Неподдерживаемый proto');
        }
        proto = tokens[1];
      } else if (key == 'dev') {
        if (tokens.length != 2 || tokens[1] != 'tun') throw const FormatException('Поддерживается только TUN');
      } else if (key == 'auth-user-pass') {
        if (tokens.length != 1) throw const FormatException('Пароль из файла запрещён');
        authNeeded = true;
      } else if (key == 'remote-cert-tls') {
        if (tokens.length != 2 || tokens[1] != 'server') throw const FormatException('Нужен сертификат сервера');
      } else if (key == 'redirect-gateway') {
        if (tokens.skip(1).any((t) => t != 'def1')) throw const FormatException('Неподдерживаемая маршрутизация');
      } else if (key == 'setenv' && tokens.length == 3 && tokens[1] == 'CLIENT_CERT' && tokens[2] == '0') {
        // Metadata emitted by some public OpenVPN configuration generators.
      } else if (_flags.contains(key)) {
        if (tokens.length != 1) throw const FormatException('Лишние параметры флага');
        hasClient |= key == 'client';
      } else if (_values.contains(key)) {
        if (tokens.length < 2 || tokens.length > 4) throw const FormatException('Некорректная директива');
      } else {
        throw FormatException('Директива не поддерживается: $key');
      }
      output.add(line);
    }
    if (block != null || !hasCa || !hasClient || host == null) {
      throw const FormatException('Нужны client, remote и закрытый inline-блок ca');
    }
    if (!output.any((l) => l.startsWith('dev '))) output.add('dev tun');
    if (!output.contains('remote-cert-tls server')) output.add('remote-cert-tls server');
    if (!output.any((l) => l.startsWith('redirect-gateway'))) output.add('redirect-gateway def1');
    if (!output.contains('auth-nocache')) output.add('auth-nocache');
    return ParsedProfile('${output.join('\n')}\n', host, port,
        proto.startsWith('tcp') ? 'tcp' : 'udp', authNeeded);
  }

  static bool validHost(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return true;
    return host.length <= 253 && RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$').hasMatch(host);
  }
}

class ParsedProfile {
  const ParsedProfile(this.text, this.host, this.port, this.transport, this.needsAuth);
  final String text, host, transport;
  final int port;
  final bool needsAuth;
}
