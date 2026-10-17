import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'network_context.dart';

class NetworkAnalysis {
  const NetworkAnalysis(this.key, this.time, this.dnsMs, this.httpsMs, this.ipHttps,
      this.udpDns, this.failures);
  final String key;
  final DateTime time;
  final int? dnsMs;
  final List<int> httpsMs;
  final bool ipHttps, udpDns;
  final List<String> failures;
  bool fresh(NetworkContext context, DateTime now) => key == context.environmentKey &&
    !context.ambiguous && now.difference(time) >= Duration.zero &&
    now.difference(time) < const Duration(minutes: 15);
  bool get preferLiteralEndpoint => dnsMs == null && ipHttps;
  bool get extraSpeedSample => httpsMs.length>=2 && jitterMs>max(500,httpsMs.reduce(min));
  Duration get candidateTimeout {
    if(httpsMs.isEmpty) return const Duration(seconds:10);
    final estimate=httpsMs.reduce(max)*3+jitterMs*2+2000;
    return Duration(milliseconds:estimate.clamp(6000,10000));
  }
  int get jitterMs => httpsMs.length < 2 ? 0 : httpsMs.reduce(max) - httpsMs.reduce(min);
  String get label => 'Анализ без VPN: DNS ${dnsMs == null ? "не подтверждён" : "$dnsMs мс"}; '
    'HTTPS ${httpsMs.length}/3${httpsMs.isEmpty ? "" : " · разброс $jitterMs мс"}; '
    'HTTPS по IP ${ipHttps ? "да" : "не подтверждён"}; DNS/UDP ${udpDns ? "да" : "не подтверждён"}';
  String get report => '$label\nВремя: ${time.toLocal()}${failures.isEmpty ? "" : "\n${failures.join('; ')}"}\n'
    'Проверка DNS/UDP не определяет доступность всех UDP-протоколов; таймаут не доказывает блокировку.';
  Map<String, dynamic> toJson() => {'key':key,'time':time.millisecondsSinceEpoch,
    'dns':dnsMs,'https':httpsMs,'ip':ipHttps,'udp':udpDns,'failures':failures};
  factory NetworkAnalysis.fromJson(Map<String,dynamic> m) => NetworkAnalysis(m['key'] as String,
    DateTime.fromMillisecondsSinceEpoch(m['time'] as int), m['dns'] as int?,
    (m['https'] as List).cast<int>(),m['ip']==true,m['udp']==true,(m['failures'] as List).cast<String>());
}

/// Owns every client/socket, so cancellation closes outstanding requests.
class NetworkAnalyzer {
  final _clients = <HttpClient>{};
  final _aborts = <Completer<int>>{};
  final _udp = <RawDatagramSocket>{};
  int _epoch = 0;
  void cancel() {
    _epoch++;
    for(final abort in _aborts.toList()) {
      if(!abort.isCompleted) abort.completeError(const HttpException('Cancelled'));
    }
    for(final c in _clients.toList()) { c.close(force:true); }
    for(final s in _udp.toList()) { s.close(); }
  }
  Future<int> https(Uri uri, {int? proxyPort, int bytes = 0, int maxBytes = 4096,
      Duration timeout = const Duration(seconds: 6)}) async {
    final token=_epoch;
    final client=HttpClient()..connectionTimeout=timeout..autoUncompress=false;
    client.findProxy=(_) => proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort';
    _clients.add(client);
    final abort=Completer<int>();
    _aborts.add(abort);
    // HttpClient.close(force:true) does not finish a stalled TLS upgrade after
    // HTTP CONNECT. Bound the awaited future itself, including cancellation.
    final timer=Timer(timeout,(){
      if(!abort.isCompleted) abort.completeError(TimeoutException('HTTPS deadline',timeout));
      client.close(force:true);
    });
    final watch=Stopwatch()..start();
    Future<int> transfer() async {
      final request=await client.getUrl(uri);
      request.followRedirects=false;
      request.headers.set('Accept-Encoding','identity');
      final response=await request.close();
      if(response.statusCode != 200 && response.statusCode != 204) throw const HttpException('HTTP status');
      var received=0;
      await for(final chunk in response) {
        if(token != _epoch) throw const HttpException('Cancelled');
        received+=chunk.length;
        if(bytes == 0 && received >= maxBytes) break;
        if(bytes > 0 && received > maxBytes) throw const HttpException('Oversized response');
      }
      if(token != _epoch || (bytes > 0 && received != bytes)) throw const HttpException('Incomplete response');
      final elapsed=max(1,watch.elapsedMilliseconds);
      return bytes == 0 ? elapsed : received*1000~/elapsed;
    }
    try {return await Future.any([transfer(),abort.future]);}
    finally {timer.cancel();client.close(force:true);_clients.remove(client);_aborts.remove(abort);}
  }
  Future<bool> _dnsUdp() async {
    final token=_epoch;
    final socket=await RawDatagramSocket.bind(InternetAddress.anyIPv4,0);
    _udp.add(socket);
    try {
      final id=Random.secure().nextInt(65536);
      final packet=<int>[id>>8,id&255,1,0,0,1,0,0,0,0,0,0,
        3,119,119,119,7,103,115,116,97,116,105,99,3,99,111,109,0,0,1,0,1];
      final answer=Completer<bool>();
      socket.listen((event) {
        if(event != RawSocketEvent.read) return;
        final d=socket.receive();
        if(d==null || d.address.address!='1.1.1.1' || d.port!=53 || d.data.length<12) return;
        final b=d.data;
        if(b[0]==id>>8 && b[1]==(id&255) && (b[2]&128)!=0 && (b[3]&15)==0 && (b[2]&2)==0 && (b[6]*256+b[7])>0 && !answer.isCompleted) answer.complete(true);
      },onDone:(){if(!answer.isCompleted) answer.complete(false);});
      socket.send(packet,InternetAddress('1.1.1.1'),53);
      return await answer.future.timeout(const Duration(seconds:3),onTimeout:()=>false) && token==_epoch;
    } finally {socket.close();_udp.remove(socket);}
  }
  Future<NetworkAnalysis> analyze(NetworkContext context) async {
    if(context.ambiguous || context.vpnPresent || context.type=='offline') throw StateError('Нет подтверждённого прямого маршрута');
    final token=_epoch;
    final errors=<String>[];
    int? dns;
    final durations=<int>[];
    var ip=false,udp=false;
    await Future.wait([
      () async {final w=Stopwatch()..start();try {await InternetAddress.lookup('www.gstatic.com').timeout(const Duration(seconds:4));dns=w.elapsedMilliseconds;} catch(e){errors.add('Системный DNS: ${e.runtimeType}');}}(),
      () async {try {udp=await _dnsUdp();}catch(e){errors.add('DNS/UDP: ${e.runtimeType}');}}(),
      () async {try {await https(Uri.parse('https://1.1.1.1/cdn-cgi/trace'));ip=true;}catch(e){errors.add('HTTPS по IP: ${e.runtimeType}');}}(),
      () async {for(var i=0;i<3 && token==_epoch;i++) {try {durations.add(await https(Uri.parse(i==1?'https://cp.cloudflare.com/generate_204':'https://www.gstatic.com/generate_204')));}catch(e){errors.add('HTTPS ${i+1}: ${e.runtimeType}');}}}(),
    ]);
    if(token!=_epoch) throw StateError('Анализ отменён');
    return NetworkAnalysis(context.environmentKey,DateTime.now(),dns,durations,ip,udp,errors);
  }
}
