import 'dart:convert';

/// Only share links are accepted; arbitrary routing, executable paths and JSON
/// configs from websites never become application configuration.
class ProxyProfile {
  ProxyProfile(this.uri, this.host, this.port, this.protocol, this.outbound);
  final String uri, host, protocol;
  final int port;
  final Map<String, dynamic> outbound;
  static String decode64(String value) => utf8.decode(base64Url.decode(base64Url.normalize(value)));
  static ProxyProfile parse(String text) {
    try { return _parse(text); }
    on FormatException { rethrow; }
    catch (_) { throw const FormatException('Некорректная ссылка сервера'); }
  }
  static ProxyProfile _parse(String text) {
    if (text.length > 131072 || RegExp(r'\s').hasMatch(text)) throw const FormatException('Вставьте одну ссылку сервера');
    if (text.startsWith('ss://') && !text.split('#').first.contains('@')) {
      final rest = text.substring(5).split('#');
      text = 'ss://${decode64(rest.first)}${rest.length > 1 ? '#${rest[1]}' : ''}';
    }
    final u = Uri.parse(text);
    final host = u.host.replaceAll(RegExp(r'^\[|\]$'), '');
    if (host.isEmpty || !RegExp(r'^[a-zA-Z0-9:.%-]+$').hasMatch(host) || !u.hasPort || u.port < 1 || u.port > 65535) {
      throw const FormatException('Укажите адрес и порт сервера (1–65535)');
    }
    if (u.path.isNotEmpty && u.path != '/') throw const FormatException('Путь должен быть параметром ссылки');
    if (u.queryParametersAll.values.any((v) => v.length != 1)) throw const FormatException('Повторяющиеся параметры ссылки');
    final q = u.queryParameters;
    if (u.scheme == 'ss') {
      if (q.keys.any((k) => k != 'outline')) throw const FormatException('Плагины Shadowsocks и дополнительные транспорты пока не поддерживаются');
      final raw = Uri.decodeComponent(u.userInfo);
      final auth = raw.contains(':') ? raw : decode64(raw);
      final split = auth.indexOf(':');
      if (split < 1 || split == auth.length - 1) throw const FormatException('Нужны шифр и пароль Shadowsocks');
      final method = auth.substring(0, split), password = auth.substring(split + 1);
      if (!{'aes-128-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305', '2022-blake3-aes-128-gcm',
        '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305'}.contains(method)) {
        throw const FormatException('Этот шифр Shadowsocks не поддерживается');
      }
      final canonical = Uri(scheme: 'ss', userInfo: base64Url.encode(utf8.encode(auth)).replaceAll('=', ''),
        host: host, port: u.port, fragment: u.fragment).toString();
      return ProxyProfile(canonical, host, u.port, 'shadowsocks', {
        'tag': 'proxy', 'protocol': 'shadowsocks', 'settings': {'servers': [
          {'address': host, 'port': u.port, 'method': method, 'password': password}]} });
    }
    if (u.scheme != 'vless') throw const FormatException('Нужна ссылка vless:// или ss://');
    if (!RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$').hasMatch(u.userInfo)) {
      throw const FormatException('Нужен UUID VLESS');
    }
    const allowed = {'type','security','sni','fp','pbk','sid','spx','flow','encryption','host','path','serviceName','mode','alpn','headerType'};
    if (q.keys.any((key) => !allowed.contains(key))) throw const FormatException('Ссылка содержит неподдерживаемые параметры VLESS');
    final network = q['type'] ?? 'tcp', security = q['security'] ?? 'none';
    if (!{'tcp','ws','grpc','xhttp'}.contains(network)) throw const FormatException('Поддерживаются TCP, WebSocket, gRPC и XHTTP');
    if (!{'none','tls','reality'}.contains(security) || (q['encryption'] ?? 'none') != 'none') {
      throw const FormatException('Неподдерживаемые настройки защиты VLESS');
    }
    if (q['headerType'] != null && q['headerType'] != 'none') throw const FormatException('HTTP-заголовки TCP не поддерживаются');
    final flow = q['flow'] ?? '';
    if (flow.isNotEmpty && (flow != 'xtls-rprx-vision' || network != 'tcp' || security == 'none')) {
      throw const FormatException('Vision требует TCP и TLS/REALITY');
    }
    final stream = <String, dynamic>{'network': network, 'security': security};
    if (security == 'tls') stream['tlsSettings'] = {
      'serverName': q['sni'] ?? host, 'fingerprint': q['fp'] ?? 'chrome',
      if (q['alpn'] != null) 'alpn': q['alpn']!.split(','),
    };
    if (security == 'reality') {
      final key = q['pbk'] ?? '', sid = q['sid'] ?? '';
      if (base64Url.decode(base64Url.normalize(key)).length != 32 || (q['sni'] ?? '').isEmpty ||
          !RegExp(r'^(?:[0-9a-fA-F]{2}){0,8}$').hasMatch(sid)) throw const FormatException('Для REALITY нужны SNI, корректный public key и short ID');
      stream['realitySettings'] = {'serverName': q['sni'], 'fingerprint': q['fp'] ?? 'chrome',
        'publicKey': key, 'shortId': sid, 'spiderX': q['spx'] ?? '/'};
    }
    if (network == 'ws') stream['wsSettings'] = {'path': q['path'] ?? '/', 'headers': {if(q['host'] != null) 'Host': q['host']}};
    if (network == 'grpc') stream['grpcSettings'] = {'serviceName': q['serviceName'] ?? '', 'multiMode': q['mode'] == 'multi'};
    if (network == 'xhttp') {
      final mode = q['mode'] ?? 'auto';
      if (!{'auto','packet-up','stream-up','stream-one'}.contains(mode)) throw const FormatException('Некорректный режим XHTTP');
      stream['xhttpSettings'] = {'path': q['path'] ?? '/', 'host': q['host'] ?? '', 'mode': mode};
    }
    return ProxyProfile(text, host, u.port, 'vless', {'tag': 'proxy', 'protocol': 'vless',
      'settings': {'vnext': [{'address': host, 'port': u.port, 'users': [
        {'id': u.userInfo, 'encryption': 'none', 'flow': flow}]}]}, 'streamSettings': stream});
  }
  String get configuration => jsonEncode({
    'log': {'loglevel': 'none'},
    'inbounds': [{'tag': 'local', 'listen': '127.0.0.1', 'port': 10807, 'protocol': 'socks', 'settings': {'udp': true}}],
    'outbounds': [outbound],
    'dns': {'servers': ['1.1.1.1', '9.9.9.9']},
    'routing': {'domainStrategy': 'AsIs', 'rules': []},
    'policy': {'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true}}, 'stats': {},
  });
}
