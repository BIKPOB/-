import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Bind both DNS and HTTPS sockets to the actual VPN interface address.
/// A broken tunnel cannot pass this test via the physical adapter.
class WindowsProbe {
  HttpClient? _client;
  RawDatagramSocket? _dns;
  int _generation = 0;
  void cancel() { _generation++; _client?.close(force: true); _dns?.close(); }
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
  Future<InternetAddress> _resolve(String host, InternetAddress local) async {
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
      return await result.future.timeout(const Duration(seconds: 6));
    } finally { await sub.cancel(); socket.close(); if (identical(_dns, socket)) _dns = null; }
  }
  Future<Map<String, dynamic>> measure(String address) async {
    final token = _generation;
    final local = InternetAddress(address);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _client = client;
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, _, _) async {
      if (token != _generation) throw const SocketException('Cancelled');
      final target = await _resolve(uri.host, local);
      return Socket.startConnect(target, uri.port, sourceAddress: local);
    };
    final clock = Stopwatch()..start();
    try {
      return await (() async {
        final request = await client.getUrl(Uri.parse('https://www.gstatic.com/generate_204'));
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 204) throw const HttpException('HTTPS status');
        await response.drain<void>();
        final download = Stopwatch()..start();
        final data = await client.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=262144'));
        data.followRedirects = false; data.headers.set('Accept-Encoding', 'identity');
        final stream = await data.close();
        if (stream.statusCode != 200) throw const HttpException('Download status');
        var bytes = 0;
        await for (final chunk in stream) {
          if (token != _generation) throw const SocketException('Cancelled');
          bytes += chunk.length;
          if (bytes >= 262144) break;
        }
        if (bytes < 262144) throw const HttpException('Incomplete download');
        final speed = 262144000 ~/ max(1, download.elapsedMilliseconds);
        return <String, dynamic>{'delay': clock.elapsedMilliseconds, 'quality': speed >= 131072,
          'bytesPerSecond': speed, 'detail': 'Windows VPN: DNS, HTTPS и 256 КиБ подтверждены · ${speed ~/ 1024} КиБ/с'};
      })().timeout(const Duration(seconds: 27));
    } catch (e) {
      return {'delay': -1, 'quality': false, 'detail': 'Проверка через интерфейс VPN: ${e.runtimeType}'};
    } finally { client.close(force: true); if (identical(_client, client)) _client = null; }
  }
}
