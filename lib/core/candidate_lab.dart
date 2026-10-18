import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../platform/candidate_host.dart';
import 'models.dart';
import 'network_analysis.dart';
import 'proxy_profile.dart';
import 'selection_policy.dart';

class CandidateResult {
  const CandidateResult(this.server, this.latencyMs, this.speeds, this.error);
  final VpnServer server;
  final int? latencyMs;
  final List<int> speeds;
  final String? error;
  bool get usable => error == null && speeds.length >= 2 && speeds.every((s)=>s>0);
  int get speed => speeds.isEmpty ? 0 : speeds.reduce(min);
  double get consistency => speeds.isEmpty ? 0 : speed/max(1,speeds.reduce(max));
  String get report => '${server.protocol} · ${server.source} · '
    '${usable ? "HTTPS подтверждён · минимум ${(speed*8/1000000).toStringAsFixed(1)} Мбит/с · ${speeds.length} замера · стабильность ${(consistency*100).round()}%" : error ?? "не проверен"}';
}

class CandidateConfig {
  static Map<String,dynamic> build(List<({String profile,String endpoint,int port})> entries) {
    if(entries.isEmpty || entries.length>3 || entries.map((e)=>e.port).toSet().length!=entries.length) throw const FormatException('Некорректная группа проверки');
    return {
      'log':{'loglevel':'none'},
      'inbounds':[for(var i=0;i<entries.length;i++) {'tag':'lab-$i','listen':'127.0.0.1',
        'port':entries[i].port,'protocol':'http','settings':<String,dynamic>{}}],
      'outbounds':[
        for(var i=0;i<entries.length;i++) _outbound(entries[i].profile,entries[i].endpoint,'candidate-$i'),
        {'tag':'block','protocol':'blackhole','settings':<String,dynamic>{}},
      ],
      'routing':{'domainStrategy':'AsIs','rules':[
        for(var i=0;i<entries.length;i++) {'type':'field','inboundTag':['lab-$i'],'outboundTag':'candidate-$i'},
      ]},
    };
  }
  static Map<String,dynamic> _outbound(String profile,String endpoint,String tag) {
    final parsed=ProxyProfile.parse(profile);
    final out=jsonDecode(jsonEncode(parsed.outbound)) as Map<String,dynamic>;
    out['tag']=tag;
    final entries=out['settings'][parsed.protocol=='vless'?'vnext':'servers'] as List;
    entries.first['address']=endpoint;
    return out;
  }
}

/// At most three proxy handshakes concurrently; speed transfers are sequential
/// to avoid grading each server against traffic from the other candidates.
class CandidateLab {
  CandidateLab(this.host, {NetworkAnalyzer? probe}) : _probe=probe??NetworkAnalyzer();
  final CandidateHost host;
  final NetworkAnalyzer _probe;
  int _epoch=0;
  Future<void>? _pending;
  Future<void> _stop() => host.stopCandidates().timeout(const Duration(seconds:5));
  Future<void> cancel() async {
    _epoch++;_probe.cancel();
    await _stop();
    final pending=_pending;
    if(pending!=null) await pending;
  }
  Future<List<CandidateResult>> run(List<VpnServer> candidates,{required bool deep,
      required bool metered, int target=131072, NetworkAnalysis? analysis, SelectionPolicy policy=const SelectionPolicy(), required Future<bool> Function() routeValid,
      required void Function(String) status, void Function(CandidateResult)? onResult,
      Future<void> Function(List<VpnServer>)? onAttempt}) async {
    final token=++_epoch;
    final done=Completer<void>();_pending=done.future;
    final results=<CandidateResult>[];
    void record(CandidateResult result) {results.add(result);onResult?.call(result);}
    var phase='Подготовка прокси';
    void update(String value) {phase=value;status(value);}
    Future<bool> validRoute() => routeValid().timeout(const Duration(seconds:5));
    final clock=Stopwatch()..start();
    final budget=Duration(seconds:deep?policy.deepSeconds:policy.fastSeconds);
    final timer=Timer(budget,(){_epoch++;_probe.cancel();unawaited(_stop().catchError((Object _) {}));});
    final progressTimer=Timer.periodic(const Duration(seconds:1),(_) {
      if(token==_epoch) status('$phase · ${clock.elapsed.inSeconds}/${budget.inSeconds} с · результатов: ${results.length}');
    });
    var checkingRoute=false;
    final routeTimer=Timer.periodic(const Duration(milliseconds:500),(_) async {
      if(checkingRoute || token!=_epoch) return;
      checkingRoute=true;
      try {
        final valid=await validRoute();
        if(token==_epoch && !valid) {_epoch++;_probe.cancel();await _stop();}
      } catch(_) {if(token==_epoch) {_epoch++;_probe.cancel();}}
      finally {checkingRoute=false;}
    });
    bool live()=>token==_epoch && clock.elapsed<budget;
    try {
      if(!await validRoute()) throw StateError('Маршрут изменился до проверки');
      final pool=candidates.where((s)=>s.protocol!='wireguard').take(deep?policy.deepCandidates:policy.fastCandidates).toList();
      final timeout=analysis?.candidateTimeout??const Duration(seconds:6);
      final rounds=deep || analysis?.extraSpeedSample==true?3:2;
      var speedTests=0, qualified=0;
      final maxSpeedTests=deep?6:3;
      // Each small group is torn down before starting the next group. Invalid
      // configuration is retried individually so one bad profile cannot veto peers.
      Future<void> group(List<VpnServer> servers) async {
        if(!live() || !await validRoute()) return;
        await onAttempt?.call(servers);
        if(!live()) return;
        update('Разрешение адресов: ${servers.length} кандидата');
        final entries=<({VpnServer server,String endpoint,int port})>[];
        await Future.wait(servers.map((s) async {
          try {
            final endpoint=await host.resolveCandidate(s.host).timeout(const Duration(seconds:5));
            final reservation=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);
            final port=reservation.port;await reservation.close();
            if(live()) entries.add((server:s,endpoint:endpoint,port:port));
          } catch(e) {if(live()) record(CandidateResult(s,null,[], 'Разрешение адреса: ${e.runtimeType}'));}
        }));
        if(entries.isEmpty || !live() || !await validRoute()) return;
        try {
          update('Запуск проверочных прокси: ${entries.length} кандидата');
          await host.startCandidates(jsonEncode(CandidateConfig.build([
            for(final e in entries) (profile:e.server.profile,endpoint:e.endpoint,port:e.port)]))).timeout(const Duration(seconds:8));
        } catch(e) {
          await _stop();
          if(e is TimeoutException) throw StateError('Проверочный Xray не ответил вовремя; запуск VPN отменён');
          if(servers.length>1) {for(final s in servers) {if(live()) await group([s]);}}
          else if(live()) {record(CandidateResult(servers.single,null,[], 'Проверочный Xray не запущен: ${e.runtimeType}'));}
          return;
        }
        try {
          update('Параллельная проверка HTTPS: ${entries.length} кандидата · системный VPN выключен');
          final passing=<({VpnServer server,int port,int latency})>[];
          await Future.wait(entries.map((e) async {
            try {
              // Domain request traverses HTTP CONNECT and resolves at the proxy,
              // not via the application's direct resolver.
              final latency=await _probe.https(Uri.parse('https://www.gstatic.com/generate_204'),proxyPort:e.port,timeout:timeout);
              if(live()) passing.add((server:e.server,port:e.port,latency:latency));
            } catch(first) {
              if(!live()) return;
              try {
                final latency=await _probe.https(Uri.parse('https://cp.cloudflare.com/generate_204'),proxyPort:e.port,timeout:timeout);
                if(live()) passing.add((server:e.server,port:e.port,latency:latency));
              } catch(second) {if(live()) record(CandidateResult(e.server,null,[], 'HTTPS через прокси: ${first.runtimeType}/${second.runtimeType}'));}
            }
          }));
          passing.sort((a,b)=>a.latency.compareTo(b.latency));
          for(final e in passing) {
            if(!live() || !await validRoute()) return;
            if(speedTests>=maxSpeedTests || qualified >= (deep?2:1)) break;
            speedTests++;
            update('Сравнение скорости · ${e.server.protocol} · ${e.server.source}');
            final speeds=<int>[];
            String? error;
            for(var round=0;round<rounds&&live();round++) {
              try {
                final size=metered?1048576:4194304;
                speeds.add(await _probe.https(Uri.https('speed.cloudflare.com','/__down',{'bytes':'$size'}),
                  proxyPort:e.port,bytes:size,maxBytes:size,timeout:const Duration(seconds:8)));
              } catch(ex) {error='Загрузка через прокси: ${ex.runtimeType}';break;}
            }
            if(live()) {
              final value=CandidateResult(e.server,e.latency,speeds,error);
              record(value);
              if(value.usable && value.speed>=target) qualified++;
            }
          }
        } finally {await _stop();}
      }
      for(var i=0;i<pool.length && live();i+=3) {
        await group(pool.sublist(i,min(i+3,pool.length)));
        if(speedTests>=maxSpeedTests || qualified >= (deep?2:1)) break;
      }
      if(token!=_epoch && clock.elapsed<budget) return [];
      if(!await validRoute()) throw StateError('Сеть изменилась: результаты отклонены');
      results.sort((a,b)=>b.speed.compareTo(a.speed));
      return results;
    } finally {
      timer.cancel();routeTimer.cancel();progressTimer.cancel();
      if(token==_epoch) _epoch++;
      _probe.cancel();
      try {await _stop();}
      finally {done.complete();if(identical(_pending,done.future)) _pending=null;}
    }
  }
}
