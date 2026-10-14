import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Bind both DNS and HTTPS sockets to the actual VPN interface address.
/// A broken tunnel cannot pass this test via the physical adapter.
class WindowsProbe {
  HttpClient? _client, _doh;
  RawDatagramSocket? _dns;
  Socket? _dnsTcp;
  int _generation = 0;
  bool _usedDoh = false;
  void cancel() { _generation++; _client?.close(force: true); _doh?.close(force: true); _dns?.close(); _dnsTcp?.destroy(); }
  static Uint8List query(String name, int id) => Uint8List.fromList([
    id >> 8, id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    for (final label in name.split('.')) ...[label.length, ...label.codeUnits], 0, 0, 1, 0, 1,
  ]);
  static InternetAddress answer(Uint8List bytes, int id) {
    if (bytes.length < 12 || bytes[0] * 256 + bytes[1] != id || (bytes[2] & 128) == 0 || (bytes[3] & 15) != 0) {
      throw const FormatException('DNS response');
    }
    var offset = 12;
    int read16(int n) => bytes[n] * 256 + bytes[n + 1];
    void skipName() {
      while (offset < bytes.length) {
        final size = bytes[offset++];
        if (size == 0) return;
        if ((size & 192) == 192) { offset++; return; }
        if (size > 63) throw const FormatException('DNS label');
        offset += size;
      }
      throw const FormatException('DNS truncated');
    }
    for (var n = 0; n < read16(4); n++) { skipName(); offset += 4; }
    for (var n = 0; n < read16(6); n++) {
      skipName();
      if (offset + 10 > bytes.length) throw const FormatException('DNS truncated');
      final type = read16(offset), cls = read16(offset + 2), length = read16(offset + 8);
      offset += 10;
      if (offset + length > bytes.length) throw const FormatException('DNS truncated');
      if (type == 1 && cls == 1 && length == 4) {
        return InternetAddress.fromRawAddress(Uint8List.sublistView(bytes, offset, offset + 4));
      }
      offset += length;
    }
    throw const FormatException('DNS A record missing');
  }
  Future<InternetAddress> _resolveUdp(String host, InternetAddress local) async {
    final id = Random.secure().nextInt(65536);
    final socket = await RawDatagramSocket.bind(local, 0);
    _dns = socket;
    final result = Completer<InternetAddress>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet == null || packet.address.address != '1.1.1.1' || packet.port != 53) return;
      try { if (!result.isCompleted) result.complete(answer(packet.data, id)); } catch (_) { }
    }, onError: (Object error) { if (!result.isCompleted) result.completeError(error); });
    try {
      socket.send(query(host, id), InternetAddress('1.1.1.1'), 53);
      return await result.future.timeout(const Duration(milliseconds: 1500));
    } finally { await sub.cancel(); socket.close(); if (identical(_dns, socket)) _dns = null; }
  }
  Future<InternetAddress> _resolveClassic(String host, InternetAddress local) async {
    final token = _generation;
    try { return await _resolveUdp(host, local); } catch (_) {
      if (token != _generation) throw const SocketException('Cancelled');
      final socket = await Socket.connect(InternetAddress('1.1.1.1'), 53,
          sourceAddress: local, timeout: const Duration(seconds: 2));
      _dnsTcp = socket;
      try {
        final id = Random.secure().nextInt(65536), data = query(host, 0);
        data[0] = id >> 8; data[1] = id & 255;
        socket.add([data.length >> 8, data.length & 255, ...data]);
        final bytes = <int>[];
        return await (() async {
          await for (final chunk in socket) {
            bytes.addAll(chunk);
            if (bytes.length >= 2) {
              final length = bytes[0] * 256 + bytes[1];
              if (length < 12) throw const FormatException('DNS TCP length');
              if (bytes.length >= length + 2) return answer(Uint8List.fromList(bytes.sublist(2, length + 2)), id);
            }
          }
          throw const SocketException('DNS TCP closed');
        })().timeout(const Duration(seconds: 2));
      } finally { socket.destroy(); if (identical(_dnsTcp, socket)) _dnsTcp = null; }
    }
  }
  Future<InternetAddress> _resolve(String host, InternetAddress local) async {
    final token = _generation;
    try { return await _resolveClassic(host, local); } catch (_) {
      if (token != _generation) throw const SocketException('Cancelled');
      // DNS-over-HTTPS fallback remains bound to the TUN address. It cannot
      // pass using the physical adapter and never disables TLS verification.
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      _doh = client;
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) async {
        final task = await Socket.startConnect(InternetAddress('1.1.1.1'), 443, sourceAddress: local);
        Socket? current;
        final secure = task.socket.then<Socket>((socket) async {
          current = socket;
          try {
            final tls = await SecureSocket.secure(socket, host: '1.1.1.1').timeout(const Duration(seconds: 3));
            current = tls;
            if (token != _generation) { tls.destroy(); throw const SocketException('Cancelled'); }
            return tls;
          } catch (_) { socket.destroy(); rethrow; }
        });
        return ConnectionTask.fromSocket(secure, () { task.cancel(); current?.destroy(); });
      };
      try {
        return await (() async {
          final id = Random.secure().nextInt(65536);
          final encoded = base64Url.encode(query(host, id)).replaceAll('=', '');
          final request = await client.getUrl(Uri.parse('https://1.1.1.1/dns-query?dns=$encoded'));
          request.followRedirects = false;
          request.headers.set('Accept', 'application/dns-message');
          final response = await request.close();
          if (response.statusCode != 200) throw const HttpException('DoH response');
          final bytes = <int>[];
          await for (final chunk in response) {
            bytes.addAll(chunk);
            if (bytes.length > 65535) throw const FormatException('DNS response too large');
          }
          _usedDoh = true;
          return answer(Uint8List.fromList(bytes), id);
        })().timeout(const Duration(seconds: 5));
      } finally { client.close(force: true); if (identical(_doh, client)) _doh = null; }
    }
  }
  Future<Map<String, dynamic>> measure(String address) async {
    _usedDoh = false;
    var phase = 'DNS';
    var bytes = 0;
    final token = _generation;
    final local = InternetAddress(address);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _client = client;
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, _, _) async {
      if (token != _generation) throw const SocketException('Cancelled');
      phase = 'DNS: ${uri.host}';
      final target = await _resolve(uri.host, local);
      phase = 'TCP: ${uri.host}:443';
      final task = await Socket.startConnect(target, uri.port, sourceAddress: local);
      Socket? current;
      final secure = task.socket.then<Socket>((socket) async {
        current = socket;
        try {
          // A custom HttpClient factory must perform TLS itself. Preserve the
          // original DNS name for SNI and certificate validation after binding.
          phase = 'TLS: ${uri.host}';
          final tls = await SecureSocket.secure(socket, host: uri.host)
              .timeout(const Duration(seconds: 8));
          current = tls;
          if (token != _generation) {
            tls.destroy();
            throw const SocketException('Cancelled');
          }
          phase = 'HTTPS-ответ: ${uri.host}';
          return tls;
        } catch (_) { socket.destroy(); rethrow; }
      });
      return ConnectionTask.fromSocket(secure, () { task.cancel(); current?.destroy(); });
    };
    final clock = Stopwatch()..start();
    try {
      return await (() async {
        final request = await client.getUrl(Uri.parse('https://www.gstatic.com/generate_204'));
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 204) throw HttpException('HTTPS status ${response.statusCode}');
        await response.drain<void>();
        final data = await client.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=262144'));
        data.followRedirects = false; data.headers.set('Accept-Encoding', 'identity');
        final stream = await data.close();
        if (stream.statusCode != 200) throw HttpException('Download status ${stream.statusCode}');
        final download = Stopwatch()..start();
        phase = 'Загрузка 256 КиБ';
        await for (final chunk in stream) {
          if (token != _generation) throw const SocketException('Cancelled');
          bytes += chunk.length;
          if (bytes >= 262144) break;
        }
        if (bytes < 262144) throw const HttpException('Incomplete download');
        final speed = 262144000 ~/ max(1, download.elapsedMilliseconds);
        if (_usedDoh) {
          return <String, dynamic>{'delay': -1, 'quality': false,
            'detail': 'HTTPS и загрузка через VPN работают с DoH, но обычный DNS туннеля не подтверждён. Автоподбор не считает это исправным системным VPN.'};
        }
        return <String, dynamic>{'delay': clock.elapsedMilliseconds, 'quality': speed >= 131072,
          'bytesPerSecond': speed, 'detail': 'Windows VPN: DNS, HTTPS и 256 КиБ подтверждены · ${speed ~/ 1024} КиБ/с'};
      })().timeout(const Duration(seconds: 27));
    } catch (e) {
      return {'delay': -1, 'quality': false, 'detail': 'Проверка через интерфейс VPN: $phase · ${e is HttpException ? e.message : e.runtimeType} · ${clock.elapsedMilliseconds} мс · $bytes байт'};
    } finally { client.close(force: true); if (identical(_client, client)) _client = null; }
  }
}
