import 'dart:convert';
import 'dart:io';
import 'proxy_profile.dart';

class ProfilePolicy {
  static const maxBytes = 128 * 1024;
  static ParsedProfile parse(String text) {
    text = text.trim();
    if (utf8.encode(text).length > maxBytes || text.contains('\u0000')) {
      throw const FormatException('Профиль слишком большой или повреждён');
    }
    if (text.startsWith('vless://') || text.startsWith('ss://')) {
      final proxy = ProxyProfile.parse(text);
      return ParsedProfile(proxy.uri, proxy.host, proxy.port, 'tcp', false, protocol: proxy.protocol);
    }
    if (RegExp(r'^\s*\[Interface\]\s*$', multiLine: true).hasMatch(text)) return _wireGuard(text);
    throw const FormatException('Нужен WireGuard .conf, ссылка vless:// или ss://. OpenVPN удалён.');
  }

  static ParsedProfile _wireGuard(String text) {
    final fields = <String, Map<String, String>>{};
    String? section;
    const standardInterface = {'privatekey', 'address', 'dns', 'mtu', 'listenport'};
    const special = {'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5', 'headerprotectionkey', 'contentpaddingaddition',
      'rekeyaftertime', 'rekeytimeout', 'rejectaftertime', 'keepalivetimeout',
      'maxhandshakeattempts', 'randomtrailers', 'disablecookies'};
    const peerKeys = {'publickey', 'presharedkey', 'endpoint', 'allowedips', 'persistentkeepalive'};
    final output = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      if (line == '[Interface]' || line == '[Peer]') {
        if (line == '[Peer]' && !fields.containsKey('[Interface]')) {
          throw const FormatException('Секция Interface должна быть перед Peer');
        }
        section = line;
        if (fields.containsKey(section)) throw const FormatException('Поддерживается один Interface и один Peer');
        fields[section] = {}; output.add(line); continue;
      }
      final split = line.indexOf('=');
      if (section == null || split < 1) throw const FormatException('Неверный формат WireGuard');
      final key = line.substring(0, split).trim().toLowerCase();
      final value = line.substring(split + 1).trim();
      final allowed = section == '[Interface]' ? {...standardInterface, ...special} : peerKeys;
      if (!allowed.contains(key) || value.isEmpty || fields[section]!.containsKey(key)) {
        throw FormatException('Директива WireGuard не поддерживается или повторяется: $key');
      }
      fields[section]![key] = value; output.add(line);
    }
    final own = fields['[Interface]'] ?? {};
    final peer = fields['[Peer]'] ?? {};
    bool keyValid(String? value) {
      if (value == null) return false;
      try { return base64Decode(value).length == 32; } catch (_) { return false; }
    }
    bool cidr(String value) {
      final parts = value.trim().split('/');
      if (parts.length != 2) return false;
      final ip = InternetAddress.tryParse(parts[0]);
      final bits = int.tryParse(parts[1]);
      return ip != null && bits != null && bits >= 0 && bits <= (ip.type == InternetAddressType.IPv4 ? 32 : 128);
    }
    if (!keyValid(own['privatekey']) || !keyValid(peer['publickey']) ||
        (peer.containsKey('presharedkey') && !keyValid(peer['presharedkey'])) ||
        (own.containsKey('headerprotectionkey') && !keyValid(own['headerprotectionkey']))) {
      throw const FormatException('Нужны действительные 32-байтовые ключи WireGuard');
    }
    if (own['address'] == null || !own['address']!.split(',').every(cidr) ||
        peer['allowedips'] == null || !peer['allowedips']!.split(',').every(cidr)) {
      throw const FormatException('Нужны Address и AllowedIPs в CIDR-формате');
    }
    final endpoint = peer['endpoint'] ?? '';
    final match = RegExp(r'^(?:\[([^\]]+)\]|([^:]+)):(\d+)$').firstMatch(endpoint);
    final host = match?.group(1) ?? match?.group(2);
    final port = int.tryParse(match?.group(3) ?? '') ?? 0;
    if (host == null || !validHost(host) || port < 1 || port > 65535) throw const FormatException('Нужен Endpoint: адрес и порт');
    // Generate initial traffic so the native engine can confirm a handshake.
    final keepalive = int.tryParse(peer['persistentkeepalive'] ?? '0');
    if (keepalive == null || keepalive < 0 || keepalive > 65535) throw const FormatException('Некорректный PersistentKeepalive');
    if (keepalive == 0) {
      output.removeWhere((line) => line.split('=').first.trim().toLowerCase() == 'persistentkeepalive');
      output.add('PersistentKeepalive = 25');
    }
    return ParsedProfile('${output.join('\n')}\n', host, port, 'udp', false,
      protocol: 'wireguard');
  }

  static bool validHost(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return true;
    return host.length <= 253 && RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$').hasMatch(host);
  }
}

class ParsedProfile {
  const ParsedProfile(this.text, this.host, this.port, this.transport, this.needsAuth, {required this.protocol});
  final String text, host, transport, protocol;
  final int port;
  final bool needsAuth;
}
