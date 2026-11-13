import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../core/speed_policy.dart';

/// Bind both DNS and HTTPS sockets to the actual VPN interface address.
/// A broken tunnel cannot pass this test via the physical adapter.
class WindowsProbe {
  WindowsProbe({Future<Map<String,dynamic>> Function(String, String)? controlProbe})
      : _controlProbe = controlProbe;
  final Future<Map<String,dynamic>> Function(String, String)? _controlProbe;
  final _children = <WindowsProbe>{};
  final _quickPending = <Completer<Map<String,dynamic>>>{};
  Future<Map<String,dynamic>> measure(String address, {bool quick=false}) async {
    if (!quick) return _measureOne(address);
    final generation = _generation;
    final done = Completer<Map<String,dynamic>>();
    _quickPending.add(done);
    final children = <WindowsProbe>[];
    final failures = <String>[];
    for (final host in ['www.gstatic.com','cp.cloudflare.com']) {
      final child = WindowsProbe(); children.add(child); _children.add(child);
      unawaited(() async {
        try {
          final result = await (_controlProbe?.call(address,host) ??
              child._measureOne(address,httpsOnly:true,control:host));
          if ((result['delay'] as num? ?? -1) >= 0 && result['httpsVerified'] == true) {
            if (!done.isCompleted && generation == _generation) done.complete(result);
            return;
          }
          failures.add('$host: ${result['detail'] ?? "HTTPS не подтверждён"}');
        } catch (error) { failures.add('$host: ${error.runtimeType}'); }
        if (failures.length == 2 && !done.isCompleted) {
          done.complete({'delay':-1,'quality':false,'detail':failures.join('; ')});
        }
      }());
    }
    try {
      return await done.future.timeout(const Duration(seconds:9),onTimeout:() =>
          {'delay':-1,'quality':false,'detail':'Лимит быстрой проверки HTTPS через Windows VPN'});
    } finally {
      _quickPending.remove(done);
      for (final child in children) { child.cancel(); _children.remove(child); }
    }
  }
  HttpClient? _client, _doh;
  RawDatagramSocket? _dns;
  Socket? _dnsTcp;
  int _generation = 0;
  bool _usedDoh = false;
  final List<String> _dnsFailures = [];
  String _failure(Object error) => error is SocketException ? 'SocketException, код ОС ${error.osError?.errorCode ?? "нет"}' : error.runtimeType.toString();
  void cancel() { _generation++;
    for (final pending in _quickPending.toList()) {
      if (!pending.isCompleted) pending.complete({'delay':-1,'quality':false,'detail':'Проверка отменена'});
    }
    for (final child in _children.toList()) { child.cancel(); }
 _client?.close(force: true); _doh?.close(force: true); _dns?.close(); _dnsTcp?.destroy(); }
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
    try { return await _resolveUdp(host, local); } catch (error) {
      _dnsFailures.add('UDP DNS: ${_failure(error)}');
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
    try { return await _resolveClassic(host, local); } catch (error) {
      _dnsFailures.add('TCP DNS: ${_failure(error)}');
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
  Future<Map<String, dynamic>> _measureOne(String address, {bool httpsOnly=false, String control='www.gstatic.com'}) async {
    _usedDoh = false; _dnsFailures.clear();
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
        final request = await client.getUrl(Uri.https(control,'/generate_204'));
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 204) throw HttpException('HTTPS status ${response.statusCode}');
        await response.drain<void>();
        final latencyMs = clock.elapsedMilliseconds; // HTTPS 204 including DNS/TLS, excluding test download.
        if (httpsOnly) {
          if (token != _generation) throw const SocketException('Cancelled');
          if (_usedDoh) {
            return {'delay':-1,'quality':false,'detail':'HTTPS доступен с DoH, обычный DNS VPN не подтверждён'};
          }
          return {'delay':clock.elapsedMilliseconds,'latencyMs':latencyMs,
            'httpsVerified':true,'quality':false,
            'detail':'Windows VPN: DNS и HTTPS через $control подтверждены; скорость не измерена'};
        }
        // Include request setup and first-byte latency so a buffered burst cannot
        // make an otherwise sluggish endpoint look fast. Bound traffic to 4 MiB.
        final download = Stopwatch()..start();
        final data = await client.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=${SpeedPolicy.sampleMaximumBytes}'));
        data.followRedirects = false; data.headers.set('Accept-Encoding', 'identity');
        final stream = await data.close();
        if (stream.statusCode != 200) throw HttpException('Download status ${stream.statusCode}');
        phase = 'Замер загрузки до 4 МиБ';
        await for (final chunk in stream) {
          if (token != _generation) throw const SocketException('Cancelled');
          bytes += chunk.length;
          if (SpeedPolicy.sampleComplete(bytes, download.elapsedMilliseconds)) break;
        }
        if (!SpeedPolicy.sampleComplete(bytes, download.elapsedMilliseconds)) throw const HttpException('Incomplete download');
        final speed = bytes * 1000 ~/ max(1, download.elapsedMilliseconds);
        if (_usedDoh) {
          return <String, dynamic>{'delay': -1, 'quality': false,
            'detail': 'HTTPS и загрузка через VPN работают с DoH, но обычный DNS туннеля не подтверждён. Автоподбор не считает это исправным системным VPN.'};
        }
        return <String, dynamic>{'delay': clock.elapsedMilliseconds, 'latencyMs': latencyMs,
          'quality': speed >= SpeedPolicy.desktopMinimum,
          'bytesPerSecond': speed, 'detail': 'Windows VPN: DNS, HTTPS и ${bytes ~/ 1024} КиБ за ${download.elapsedMilliseconds} мс · ${(speed * 8 / 1000000).toStringAsFixed(2)} Мбит/с'};
      })().timeout(const Duration(seconds: 27));
    } catch (e) {
      return {'delay': -1, 'quality': false, 'detail': 'Проверка через интерфейс VPN: $phase · ${e is HttpException ? e.message : e is SocketException ? 'SocketException · код ОС ${e.osError?.errorCode ?? 'нет'} · ${token != _generation ? 'проверка отменена' : 'ошибка сети'}' : e.runtimeType} · ${clock.elapsedMilliseconds} мс · $bytes байт${_dnsFailures.isEmpty ? '' : ' · ${_dnsFailures.join('; ')} · последний этап DNS: DoH'}'};
    } finally { client.close(force: true); if (identical(_client, client)) _client = null; }
  }
}
