import '../core/handover_policy.dart';
import '../core/search_rotation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/models.dart';
import '../core/traffic.dart';
import '../core/profile_policy.dart';
import '../core/server_monitor.dart';
import '../data/profile_store.dart';
import '../data/public_catalog.dart';
import '../core/adaptive_selector.dart';
import '../core/connection_strategy.dart';
import '../core/network_analysis.dart';
import '../core/candidate_lab.dart';
import '../core/selection_policy.dart';
import '../platform/candidate_host.dart';
import '../core/network_context.dart';
import '../core/network_baseline.dart';
import '../core/speed_policy.dart';
import '../platform/vpn_engine.dart';
import '../platform/desktop_capabilities.dart';

class VpnViewModel extends ChangeNotifier {
  VpnViewModel(this.engine, this.store, this.monitor, {
    Future<PublicCatalogResult> Function()? catalogLoader, NetworkAnalyzer? networkAnalyzer, BaselineMonitor? baselineMonitor,
    CandidateLab Function(ReserveCandidateHost)? reserveLabFactory, DateTime Function()? reserveClock,
    Future<String> Function()? networkReader, ServerMonitor? autoMonitor, ServerMonitor? backgroundMonitor,
  }) : _baselineMonitor=baselineMonitor??BaselineMonitor(), _networkAnalyzer=networkAnalyzer??NetworkAnalyzer(), _reserveLabFactory=reserveLabFactory, _reserveNow=reserveClock??DateTime.now,
       _catalogLoader = catalogLoader ?? PublicCatalog().load,
       _networkReader = networkReader, _autoMonitor = autoMonitor ?? ServerMonitor(tcpOnly: true),
       _backgroundMonitor = backgroundMonitor ?? ServerMonitor(tcpOnly: true);
  final Future<PublicCatalogResult> Function() _catalogLoader;
  final Future<String> Function()? _networkReader;
  final VpnEngine engine;
  final ProfileStore store;
  final ServerMonitor monitor;
  List<VpnServer> _imports = [];
  List<VpnServer> get servers => _imports;
  List<VpnServer> get filtered => servers.where((s) => (country == null || s.country == country) && (protocolFilter == null || s.protocol == protocolFilter)).toList();
  Map<String, HealthResult> health = {};
  ConnectionState state = ConnectionState.disconnected;
  String? selectedId, country, message, protocolFilter;
  VpnServer? activeServer;
  bool busy = false, ready = false;
  bool autoSelecting = false, connectionVerified = false;
  String? autoStatus;
  int _autoEpoch = 0;
  AdaptiveSelector _selector = AdaptiveSelector();
  final ServerMonitor _autoMonitor;
  final ServerMonitor _backgroundMonitor;
  Map<String, HealthResult> _backgroundHealth = {};
  DateTime? _backgroundMeasuredAt;
  NetworkContext? _backgroundContext;
  Timer? _backgroundTimer;
  int _backgroundEpoch = 0;
  String? backgroundStatus;
  final BaselineMonitor _baselineMonitor;
  Timer? _baselineTimer;
  NetworkBaseline? baseline;
  String baselineStatus = 'Наблюдение за вашей сетью: ожидание замера без VPN';
  int? _selectionTarget;
  final NetworkAnalyzer _networkAnalyzer;
  CandidateLab? _candidateLab;
  NetworkAnalysis? networkAnalysis;
  bool analyzingNetwork = false;
  String analysisStatus = 'Автоанализ сети: ожидание прямого маршрута';
  Map<String,dynamic> _labStorage = {};
  Future<void>? _analysisPending;
  SelectionPolicy _policy = const SelectionPolicy();
  String get networkAnalysisReport => networkAnalysis?.fresh(networkContext,DateTime.now())==true ? networkAnalysis!.report : analysisStatus;
  Future<void> _saveLab() async {
    try { await store.saveNetworkLab(jsonEncode(_labStorage)); } catch (_) { }
  }
  Future<void> analyzeNetwork({bool force=false}) async {
    if(engine is! CandidateHost || _nativeNeedsStop || _disposed || (!_foreground && !Platform.isWindows)) return;
    final context=await _network();networkContext=context;
    await _analyzeNetwork(context,force:force);
  }
  Future<void> _analyzeNetwork(NetworkContext context,{bool force=false}) async {
    if(_analysisPending!=null) await _analysisPending;
    if (_disposed) return;
    if(context.vpnPresent || context.ambiguous || context.type=='offline') {
      analysisStatus='Анализ отложен: нет однозначного прямого маршрута без VPN';return;
    }
    final maxAge = force ? const Duration(seconds:30)
        : Duration(minutes:context.metered==false ? 2 : 5);
    if(networkAnalysis?.fresh(context,DateTime.now(),maxAge:maxAge)==true) return;
    final done=Completer<void>();_analysisPending=done.future;analyzingNetwork=true;_notify();
    try {
      final now=DateTime.now();final day=now.toUtc().toIso8601String().substring(0,10);
      final used=_labStorage['analysisDay']==day?(_labStorage['analysisCount'] as num?)?.toInt()??0:0;
      if(used >= (context.metered==false?720:288)) {analysisStatus='Достигнут суточный лимит коротких анализов сети';return;}
      _labStorage.addAll({'analysisDay':day,'analysisCount':used+1});await _saveLab();
      analysisStatus='Проверка системного DNS, DNS/UDP, HTTPS по IP и трёх HTTPS-ответов';_notify();
      final value=await _networkAnalyzer.analyze(context);
      final after=await _network();
      if(_disposed || after.vpnPresent || !context.sameConnection(after) || after.ambiguous) {
        analysisStatus='Сеть изменилась: прямые измерения отклонены';return;
      }
      networkAnalysis=value;analysisStatus=value.label;
      final entries=(_labStorage['analyses'] as List? ?? []).whereType<Map>()
        .where((m)=>m['key']!=value.key).take(7).toList();
      _labStorage['analyses']=[value.toJson(),...entries];await _saveLab();
    } catch(e) {analysisStatus='Анализ сети не завершён: ${e.runtimeType}';}
    finally {analyzingNetwork=false;done.complete();_analysisPending=null;if(!_disposed)_notify();}
  }
  Future<void> _refreshPolicy() async {
    final last=DateTime.fromMillisecondsSinceEpoch((_labStorage['policyTime'] as num?)?.toInt()??0);
    if(DateTime.now().difference(last)<const Duration(hours:6)) return;
    _labStorage['policyTime']=DateTime.now().millisecondsSinceEpoch;
    try {
      final text=await SelectionPolicy.fetch();final next=SelectionPolicy.parse(text);
      if(next.version>=_policy.version) {_policy=next;_labStorage['policy']=text;}
    } catch(_) { /* Offline rules remain available. */ }
    await _saveLab();
  }
  static List<VpnServer> _transportDiversity(List<VpnServer> ranked) {
    final groups=<String,List<VpnServer>>{};
    for(final s in ranked) {
      final q=Uri.tryParse(s.profile)?.queryParameters;
      final key='${s.protocol}|${q?['type']??"tcp"}|${q?['security']??"none"}';
      groups.putIfAbsent(key,()=>[]).add(s);
    }
    final result=<VpnServer>[];
    for(var round=0;;round++) {
      var added=false;
      for(final group in groups.values) {if(round<group.length){result.add(group[round]);added=true;}}
      if(!added) return result;
    }
  }
  bool get _desktop => engine is DesktopCapabilities;
  bool get _requiresSpeed => _desktop || engine is CandidateHost;
  int get targetBytesPerSecond => _requiresSpeed ? SpeedPolicy.networkTarget(_selectionTarget) : _selectionTarget ?? 131072;
  void _scheduleBaseline({bool immediate = false, bool forceAnalysis = false}) {
    _baselineTimer?.cancel();
    if (_disposed || !ready || (!Platform.isWindows && !_foreground)) return;
    _baselineTimer = Timer(Duration(seconds: immediate ? 1 : 30), () async {
      try {
        if (!autoSelecting && !_nativeNeedsStop && !busy) {
          final context = await _network();
          if (_disposed || autoSelecting || _nativeNeedsStop || busy) return;
          networkContext = context;
          if (networkAnalysis?.fresh(context,DateTime.now()) != true) {
            networkAnalysis = null;
            analysisStatus = 'Автоанализ текущей сети: обновление';
          }
          if (baseline?.fresh(context,DateTime.now()) != true) baseline = null;
          if(engine is CandidateHost) await _analyzeNetwork(context,force:forceAnalysis);
          if (_disposed || autoSelecting || _nativeNeedsStop || busy) return;
          await _baselineMonitor.pause(false);
          final result = await _baselineMonitor.tick(context, readNetwork: _network);
          if (_disposed) return;
          final current = await _network();
          if (context.sameConnection(current) && result?.fresh(current, DateTime.now()) == true) {
            baseline = result;
            baselineStatus = '${result!.label} · цель VPN ${(result.target * 8 / 1000000).toStringAsFixed(1)} Мбит/с (60%)';
          } else {
            baseline = null;
            baselineStatus = 'Ваша сеть: ${current.label} · ${_baselineMonitor.status}';
          }
        }
      } catch (_) { baselineStatus = 'Прямой замер временно недоступен; наблюдение продолжается'; }
      finally { if (!_disposed) { _notify(); _scheduleBaseline(); } }
    });
  }
  static const _networkChannel = MethodChannel('quietvpn/catalog-cache');
  NetworkContext networkContext = const NetworkContext();
  final List<String> autoAttemptReports = [];
  String autoPlan = '';
  bool extendedNetwork = false, requestingNetworkPermission = false;
  int? measuredBytesPerSecond;
  int get learningSamples => _selector.samples;
  List<Map<String, dynamic>> get learningJournal => List.unmodifiable(_selector.journal);
  Future<void> enableNetworkAnalysis() async {
    if (requestingNetworkPermission || autoSelecting) return;
    requestingNetworkPermission = true;
    try {
      final context = await _network();
      // Wi-Fi signal and frequency use a normal manifest permission. No location is collected.
      if (context.type == 'mobile' && Platform.isAndroid) await Permission.phone.request();
      extendedNetwork = true;
      networkContext = await _network();
      await analyzeNetwork();
    } finally { requestingNetworkPermission = false; _notify(); }
  }
  Future<void> resetLearning() async {
    if (autoSelecting) return;
    _selector = AdaptiveSelector();
    await store.saveSelector(_selector.encode()); _notify();
  }
  Future<void> _remember(VpnServer server, NetworkContext context, int? latency,
      String outcome, {int? speed, double? reward}) async {
    if (reward != null) {
      _selector.observe(server, context.type, latency, success: reward >= .5, context: context, reward: reward);
    }
    _selector.record(server, context, outcome, speed: speed);
    try { await store.saveSelector(_selector.encode()); } catch (_) { }
  }

  Future<NetworkContext> _network() async {
    if (_networkReader != null) return NetworkContext(type: await _networkReader());
    if (engine is DesktopCapabilities) return (engine as DesktopCapabilities).readNetwork();
    try {
      final data = await _networkChannel.invokeMapMethod<dynamic, dynamic>('networkContext', {'extended': extendedNetwork});
      return NetworkContext.fromMap(data ?? {});
    } catch (_) { return const NetworkContext(); }
  }
  Future<void> cancelAutoSelection({String reason = 'Подбор остановлен пользователем'}) async {
    _cancelReserve();
    _autoEpoch++; _autoMonitor.cancel(); _networkAnalyzer.cancel();
    await _candidateLab?.cancel();
    autoStatus = reason; _notify();
    if (!busy && _nativeNeedsStop) await disconnect();
  }
  final _searchVisited = <String>{};
  DateTime? _searchDeadline;
  PublicCatalogResult? _searchCatalog;
  bool _roundCanContinue = false;
  Future<void> autoConnect({bool deep = false}) async {
    if (!ready || busy || autoSelecting || _nativeNeedsStop || _stopping) return;
    autoSelecting = true;
    _searchVisited.clear();
    _searchCatalog = null;
    _searchDeadline = DateTime.now().add(Duration(minutes:deep ? 12 : 4));
    final reports = <String>[];
    final rounds = deep ? 4 : 2;
    try {
      for (var round=1; round<=rounds; round++) {
        if (_disposed || !DateTime.now().isBefore(_searchDeadline!)) break;
        _roundCanContinue = false;
        final visited = _searchVisited.length;
        final expectedEpoch = _autoEpoch + 1;
        await _autoConnectRound(deep:deep);
        reports.add('Раунд $round/$rounds · ${deep ? "глубокий" : "быстрый"} подбор');
        reports.addAll(autoAttemptReports);
        if (_disposed || _autoEpoch != expectedEpoch || !_roundCanContinue ||
            _nativeNeedsStop || _searchVisited.length == visited) { break; }
      }
    } finally {
      if (_roundCanContinue && !_nativeNeedsStop && !connectionVerified) {
        final total = reports.where((r)=>r.startsWith('Попытка ')).length;
        autoStatus = reports.any((r)=>r.startsWith('Восстановление '))
            ? 'Проверено $total вариантов: повторное подключение не прошло проверку. Подробности в диагностике.'
            : 'Проверено $total вариантов: подходящая скорость не подтверждена. Медленный VPN автоматически не сохранён.';
      }
      autoAttemptReports..clear()..addAll(reports);
      try { await store.saveAttempts('${DateTime.now().toIso8601String()}\n${reports.join('\n\n')}'); } catch (_) { }
      _searchDeadline = null;
      _searchCatalog = null;
      _searchVisited.clear();
      autoSelecting = false;
      if (!_disposed) { _scheduleProbe(); _scheduleBackgroundPreflight(); _scheduleBaseline(immediate:true); _notify(); }
    }
  }
  Future<void> _autoConnectRound({required bool deep}) async {

    if (!ready || busy || _nativeNeedsStop || _stopping) return;
    _cancelReserve();
    autoSelecting = true; final token = ++_autoEpoch;
    autoAttemptReports.clear();
    autoPlan = ''; protocolFilter = null; country = null;
    autoStatus = 'Локальная нейросеть: обновление базы'; _notify();
    _poll?.cancel(); _probeEpoch++; monitor.cancel();
    _backgroundTimer?.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    bool cancelled() => token != _autoEpoch || _disposed;
    try {
      await _reserveLab?.cancel();
      if (cancelled()) return;
      final context = await _network();
      networkContext = context;
      if (engine is CandidateHost && !context.vpnPresent && !context.ambiguous &&
          context.type != 'offline' && baseline?.fresh(context, DateTime.now()) != true) {
        autoStatus = 'Оценка скорости вашей сети без VPN'; _notify();
        try {
          await _baselineMonitor.pause(false);
          final sample = await _baselineMonitor.tick(context, readNetwork: _network, forSelection:true)
              .timeout(const Duration(seconds: 15));
          if (cancelled()) return;
          final after = await _network();
          if (!after.vpnPresent && context.sameConnection(after) && sample?.fresh(after, DateTime.now()) == true) {
            baseline = sample;
            baselineStatus = '${sample!.label} · приблизительная скорость до тестового узла';
          }
        } catch (_) { baselineStatus = 'Прямой замер недоступен; используется резервная цель скорости'; }
      }
      if (cancelled()) return;
      _selectionTarget = baseline?.fresh(context, DateTime.now()) == true ? baseline!.target : null;
      await _baselineMonitor.pause(true);
      if(engine is CandidateHost) {
        await _analyzeNetwork(context,force:true);
        if(cancelled()) return;
        await _refreshPolicy();
        if(cancelled()) return;
        autoAttemptReports.add(networkAnalysis?.fresh(context,DateTime.now())==true ? networkAnalysis!.report : analysisStatus);
        autoAttemptReports.add('Правила РФ v${_policy.version}: до ${deep?_policy.deepCandidates:_policy.fastCandidates} прокси-кандидатов, бюджет ${deep?_policy.deepSeconds:_policy.fastSeconds} с; скорость измеряется последовательно');
      }
      final network = context.type;
      if (cancelled()) return;
      if (network == 'offline') { autoStatus = 'Нет доступной сети'; return; }
      if(engine is CandidateHost && (context.vpnPresent || context.ambiguous)) {
        autoStatus=context.vpnPresent ? 'Прямая проверка отложена: обнаружен другой VPN или внешний маршрут через виртуальный адаптер. Отключите его перед подбором.' : 'Подбор остановлен: базовая сеть неоднозначна';
        return;
      }
      final catalog = _searchCatalog ??= await _catalogLoader();
      if (cancelled()) return;
      final pool = [..._imports, ...catalog.servers].where((s) =>
        !_searchVisited.contains(ConnectionStrategy.profileKey(s)) &&
        (!_desktop || s.protocol != 'vless' || ConnectionStrategy.protectedVless(s))).toList();
      autoAttemptReports.add('База: ${catalog.status}\n'
        '${['wireguard', 'vless', 'shadowsocks'].map((p) => '$p: ${pool.where((s) => s.protocol == p).length} профилей').join('; ')}');
      final rotationData = Map<String,dynamic>.from((_labStorage['rotation'] as Map?) ?? {});
      final rotation = SearchRotation(rotationData);
      final rotationNetwork = sha256.convert(utf8.encode(context.environmentKey)).toString();
      String rotationKey(VpnServer s) => sha256.convert(utf8.encode(ConnectionStrategy.profileKey(s))).toString();
      List<VpnServer> rotate(List<VpnServer> servers) => rotation.order(
        servers, rotationNetwork, rotationKey, DateTime.now());
      Future<void> attempted(List<VpnServer> servers) async {
        _searchVisited.addAll(servers.map(ConnectionStrategy.profileKey));
        rotation.mark(rotationNetwork, servers.map(rotationKey), DateTime.now());
        _labStorage['rotation'] = rotationData;
        await _saveLab();
      }
      int priority(VpnServer server) {
        final speed = _selector.recentSpeed(server, context);
        if (_requiresSpeed && speed > 0 && speed < targetBytesPerSecond) return -1;
        return _selector.recentPriority(server, context);
      }
      int rank(VpnServer a, VpnServer b, Map<String, HealthResult>? latency) {
        final recent = priority(b).compareTo(priority(a));
        if (recent != 0) return recent;
        if(networkAnalysis?.fresh(context,DateTime.now())==true && networkAnalysis!.preferLiteralEndpoint) {
          final literal=(InternetAddress.tryParse(b.host)!=null?1:0).compareTo(InternetAddress.tryParse(a.host)!=null?1:0);
          if(literal!=0) return literal;
        }
        int reachability(VpnServer server) => latency?[server.id]?.state == Reachability.reachable ? 1
          : latency?[server.id]?.state == Reachability.unreachable ? -1 : 0;
        final reachable = reachability(b).compareTo(reachability(a));
        if (reachable != 0) return reachable;
        final speed = _selector.recentSpeed(b, context).compareTo(_selector.recentSpeed(a, context));
        if (speed != 0) return speed;
        final score = _selector.score(b, network, latency?[b.id]?.milliseconds, context: context)
          .compareTo(_selector.score(a, network, latency?[a.id]?.milliseconds, context: context));
        if (score != 0) return score;
        // Untested UDP is not known-bad, but avoid spending the first 20s on it.
        return (a.protocol == 'wireguard' ? 1 : 0).compareTo(b.protocol == 'wireguard' ? 1 : 0);
      }
      // Broader source exploration uses bounded TCP probes, not one ping process per profile.
      final candidates = <VpnServer>[];
      final hosts = <String>{};
      for (final protocol in ['wireguard', 'vless', 'shadowsocks']) {
        final group = pool.where((s) => s.protocol == protocol).toList()
          ..sort((a, b) => rank(a, b, null));
        var count = 0;
        final diverse = [for (final tier in [1, 0, -1])
          ...PublicCatalog.diverse(group.where((server) => priority(server) == tier).toList())];
        for (final server in rotate(diverse)) {
          if (count >= (protocol == 'wireguard' ? 8 : 24)) break;
          if (hosts.add(sha256.convert(utf8.encode(server.profile)).toString())) { candidates.add(server); count++; }
        }
      }
      autoStatus = 'Сеть: ${context.label} · оценка ${candidates.length} адресов · опыт: ${_selector.samples}'; _notify();
      final cacheFresh = _backgroundMeasuredAt != null && _backgroundContext?.sameConnection(context) == true &&
        DateTime.now().difference(_backgroundMeasuredAt!) < const Duration(minutes: 3);
      final latency = <String, HealthResult>{
        if (cacheFresh) for (final server in candidates)
          if (_backgroundHealth[server.id] case final value?) server.id: value,
      };
      final missing = candidates.where((server) => !latency.containsKey(server.id)).toList();
      if (engine is! CandidateHost && missing.isNotEmpty) latency.addAll(await _autoMonitor.sample(missing));
      if (cancelled()) return;
      // Recheck negatives once, including cached negatives, before lowering
      // their scheduling priority. Do not persist this as a failed protocol handshake.
      final unavailable = candidates.where((s) => latency[s.id]?.state == Reachability.unreachable).toList();
      if (engine is! CandidateHost && unavailable.isNotEmpty) {
        latency.addAll(await _autoMonitor.sample(unavailable));
        if (cancelled()) return;
      }
      if (!context.sameConnection(await _network())) { autoStatus = 'Сеть изменилась — запустите подбор заново'; return; }
      if (cancelled()) return;
      final failedPreflight = candidates.where((s) => latency[s.id]?.state == Reachability.unreachable).toList();
      final skippedTcp = failedPreflight.length;
      for (final server in failedPreflight) {
        _selector.record(server, context, 'preflight_unreachable');
      }
      // Ten-minute scheduling cooldown, not neural training or a permanent ban.
      if (failedPreflight.isNotEmpty) {
        try { await store.saveSelector(_selector.encode()); } catch (_) { }
        if (cancelled()) return;
      }
      if (skippedTcp > 0) autoAttemptReports.add('TCP: $skippedTcp адресов не ответили при повторной проверке; оставлены в резерве для проверки туннеля. Это не доказывает блокировку.');
      candidates.sort((a, b) => rank(a, b, latency));
      final mixed = [for (final tier in [1, 0, -1])
        ...PublicCatalog.diverse(candidates.where((s) => priority(s) == tier).toList())];
      var ordered = ConnectionStrategy.select(mixed, limit: deep ? 8 : 6, priority: priority);
      if(engine is CandidateHost) {
        final lab=_candidateLab ??= CandidateLab(engine as CandidateHost);
        final proxyRanked=_transportDiversity(mixed.where((s)=>s.protocol!='wireguard').toList());
        final limit=deep?_policy.deepCandidates:_policy.fastCandidates;
        final known=proxyRanked.where((s)=>_selector.recentSpeed(s,context)>=targetBytesPerSecond).toList()
          ..sort((a,b)=>_selector.recentSpeed(b,context).compareTo(_selector.recentSpeed(a,context)));
        final benchmark=known.isEmpty?null:known.first;
        final proxyPool=[...rotate(proxyRanked.where((s)=>s!=benchmark).toList()).take(limit-(benchmark==null?0:1)),
          if(benchmark!=null) benchmark];
        autoAttemptReports.add('Ротация: сначала ещё не проверенные в этой сети; затем проверенные давно. До ${proxyPool.length} кандидатов, история до 7 дней.');
        Future<NetworkContext>? routeRead;
        NetworkContext? routeSnapshot;
        DateTime? routeReadAt;
        Future<bool> validRoute() async {
          if(cancelled()) return false;
          if(routeSnapshot==null || routeReadAt==null || DateTime.now().difference(routeReadAt!)>=const Duration(milliseconds:500)) {
            final pending=routeRead ??= _network();
            try {routeSnapshot=await pending;routeReadAt=DateTime.now();}
            finally {if(identical(routeRead,pending)) routeRead=null;}
          }
          final current=routeSnapshot!;
          return !cancelled() && !current.vpnPresent && !current.ambiguous && context.sameConnection(current);
        }
        final analysis=networkAnalysis?.fresh(context,DateTime.now())==true?networkAnalysis:null;
        autoAttemptReports.add('Профиль сети: таймаут HTTPS через прокси ${analysis?.candidateTimeout.inSeconds??6} с; '
          '${analysis?.preferLiteralEndpoint==true?"IP-адреса серверов получают приоритет из-за неподтверждённого системного DNS":"имена и IP сохраняются в подборе"}; '
          'замеров скорости ${deep || analysis?.extraSpeedSample==true?3:2}');
        final findings=await lab.run(proxyPool,deep:deep,metered:context.metered!=false,target:targetBytesPerSecond,analysis:analysis,policy:SelectionPolicy(
            fastCandidates:_policy.fastCandidates,deepCandidates:_policy.deepCandidates,
            fastSeconds:min(_policy.fastSeconds,max(1,_searchDeadline!.difference(DateTime.now()).inSeconds)),
            deepSeconds:min(_policy.deepSeconds,max(1,_searchDeadline!.difference(DateTime.now()).inSeconds))),
          onAttempt:attempted, routeValid:validRoute, status:(value){autoStatus=value;_notify();},
          onResult:(finding){
            autoAttemptReports.add('Прокси-проверка: ${finding.report}');_notify();
          });
        if(cancelled()) return;
        for(final f in findings) {
          if(f.usable) {
            await _remember(f.server,context,f.latencyMs,
              'proxy_verified',speed:f.speed,reward:.2+.8*(f.speed/(f.speed+targetBytesPerSecond))*f.consistency);
          }
          else if(f.error?.startsWith('HTTPS через прокси:')==true) {
            await _remember(f.server,context,null,'proxy_unconfirmed');
          }
        }
        final usable=findings.where((f)=>f.usable).toList();
        ordered=ConnectionStrategy.tunnelQueue(
          usable.map((f)=>f.server).toList(), mixed, deep:deep, priority:priority,
          screened: findings.where((f)=>!f.usable).map((f)=>ConnectionStrategy.profileKey(f.server)).toSet());
        autoAttemptReports.add('Прокси: в выборке ${proxyPool.length}, результатов ${findings.length}, '
          'подтверждено ${usable.length}. Очередь VPN: ${ordered.length}/${deep ? 8 : 6}; '
          'неподтверждённые кандидаты требуют проверки туннеля.');
        if(ordered.isEmpty) {
          _roundCanContinue=true;
          autoStatus='Прокси-проверка не нашла подтверждённого HTTPS и загрузки. VPN не включён; подробности в диагностике.';
          return;
        }
      }
      final finalists = <({VpnServer server, double utility, int speed, bool qualified})>[];
      autoPlan = '${_selectionTarget == null && !_requiresSpeed ? '' : 'Цель скорости: ${(targetBytesPerSecond * 8 / 1000000).toStringAsFixed(1)} Мбит/с · '}${deep ? 'Глубокий' : 'Быстрый'} подбор · план: ${ordered.map((s) => s.protocol).join(' → ')}';
      autoAttemptReports.add(autoPlan);
      // Give all eight tunnel attempts their own time after proxy screening.
      final searchClock = Stopwatch()..start();
      final budget = Duration(seconds:min(deep ? 640 : 120,max(1,_searchDeadline!.difference(DateTime.now()).inSeconds)));
      var attempt = 0;
      for (final server in ordered) {
        if (cancelled()) return;
        if (searchClock.elapsed >= budget) {
          autoAttemptReports.add('Лимит времени этапа VPN: проверено $attempt/${ordered.length}');
          break;
        }
        if (deep && finalists.where((candidate) => !_requiresSpeed || candidate.qualified).length >= 2) break;
        if (!context.sameConnection(await _network())) { autoStatus = 'Сеть изменилась — запустите подбор заново'; return; }
        if (cancelled()) return;
        await attempted([server]);
        if (cancelled()) return;
        attempt++;
        autoStatus = 'ИИ-подбор: попытка $attempt/${ordered.length} · ${server.protocol} · подключение и проверка'; _notify();
        await importProfile(server.profile, server.name, 'ИИ-подбор · ${server.source}', updateFilter: false);
        if (cancelled()) return;
        await connect(null);
        if (_localNetworkFailure) {
          autoStatus = 'Подбор остановлен: ошибка выбора базовой сети, серверы не оценивались';
          autoAttemptReports.add('Подготовка подключения: ${message ?? "базовая сеть недоступна"}. Туннель не запускался; результат не записан как отказ сервера.');
          return;
        }
        final remaining=max(1,budget.inMilliseconds-searchClock.elapsedMilliseconds);
        final deadline = DateTime.now().add(Duration(milliseconds:min(70000,remaining)));
        while (!cancelled() && (state == ConnectionState.connecting || _stopping) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        final duringVpn = await _network();
        final sameNetwork = context.sameConnection(duringVpn);
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        var success = state == ConnectionState.connected && connectionVerified;
        if (_selectionTarget != null || _requiresSpeed) {
          success = state == ConnectionState.connected && (measuredBytesPerSecond ?? 0) >= targetBytesPerSecond;
        }
        final speeds = <int>[];
        if (measuredBytesPerSecond != null) speeds.add(measuredBytesPerSecond!);
        var repeatFailed = false;
        if (deep && state == ConnectionState.connected && measuredBytesPerSecond != null && sameNetwork) {
          for (var round = 0; round < 2; round++) {
            autoStatus = 'Сравнение $attempt/${ordered.length} · ${server.protocol} · замер ${round + 2}/3'; _notify();
            try {
              final result = await _probeTunnel();
              if (cancelled()) return;
              final current = await _network();
              if (!context.sameConnection(current)) {
                if (_nativeNeedsStop) await disconnect();
                autoStatus = 'Сеть изменилась — результаты не смешиваются'; return;
              }
              final speed = (result?['bytesPerSecond'] as num?)?.toInt();
              if ((result?['delay'] as num? ?? -1) < 0 || speed == null) { repeatFailed = true; break; }
              speeds.add(speed);
            } catch (_) { repeatFailed = true; break; }
          }
          if (cancelled()) return;
          speeds.sort();
          success = !repeatFailed && SpeedPolicy.stableSamples(speeds, targetBytesPerSecond);
        }
        final medianSpeed = speeds.isEmpty ? null : speeds[speeds.length ~/ 2];
        final usable = state == ConnectionState.connected && !repeatFailed &&
            medianSpeed != null && medianSpeed > 0 && sameNetwork;
        // Short repeated downloads measure consistency, not long-session stability.
        final utility = medianSpeed == null ? 0.0 :
          (.75 * (medianSpeed / (medianSpeed + 524288)) +
           .25 * (speeds.first / max(1, speeds.last))).toDouble();
        final attemptResult = success ? 'успех' : usable ? 'работает, ниже цели' : 'не подтверждено';
        autoAttemptReports.add('Попытка $attempt · ${server.protocol} · $attemptResult · ${server.source}\n${message ?? connectionStage ?? 'Нет подробностей'}');
        if (sameNetwork && !context.ambiguous && !duringVpn.ambiguous) {
          await _remember(server, context, latency[server.id]?.milliseconds,
            success ? 'verified' : usable ? 'usable' : medianSpeed != null ? 'slow_or_unstable' : 'unconfirmed',
            speed: medianSpeed, reward: medianSpeed == null || repeatFailed ? null : .2 + .8 * utility);
        }
        if (usable && !context.ambiguous && (!_requiresSpeed || success)) {
          finalists.add((server: server, utility: utility, speed: speeds.first, qualified: success));
          autoAttemptReports.add('${speeds.length} замер(а): ${speeds.map((n) => '${(n / 1024).round()} КиБ/с').join(', ')}');
        }
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        if (!deep && (success || (usable && _selectionTarget == null && !_requiresSpeed)) && sameNetwork) {
          connectionVerified = success;
          autoStatus = success
            ? 'ИИ выбрал соединение с подтверждённым HTTPS · опыт: ${_selector.samples}'
            : 'ИИ сохранил первый рабочий VPN; скорость ниже цели. Глубокий подбор может найти быстрее.';
          return;
        }
        // Proxy candidates were compared before TUN activation. Once the live
        // tunnel meets the goal in all three samples, preserve this session:
        // disconnect/reconnect can yield a different route or fail entirely.
        if (deep && _requiresSpeed && success && usable &&
            !context.ambiguous && !duringVpn.ambiguous && speeds.length == 3) {
          connectionVerified = true;
          measuredBytesPerSecond = medianSpeed;
          autoStatus = 'Сохранён текущий VPN: цель скорости подтверждена в 3 замерах; дальнейшие переключения остановлены';
          return;
        }
        // Keep the best live tunnel when comparison is complete: reconnecting
        // a public endpoint can fail even immediately after a successful sample.
        final comparisonDone = finalists.where((candidate) => !_requiresSpeed || candidate.qualified).length >= 2 || server == ordered.last || searchClock.elapsed >= budget;
        if (deep && usable && (!_requiresSpeed || success) && !context.ambiguous && comparisonDone &&
            finalists.every((candidate) => _requiresSpeed ? candidate.speed <= speeds.first : candidate.utility <= utility)) {
          connectionVerified = success;
          measuredBytesPerSecond = medianSpeed;
          autoStatus = success ? 'Сохранён лучший из ${finalists.length} измеренных вариантов без переподключения'
            : 'Сохранён резервный VPN; скорость ниже цели или нестабильна.';
          return;
        }
        final failure = message;
        if (_nativeNeedsStop) await disconnect();
        message = failure;
        if (_nativeNeedsStop) { autoStatus = 'Подбор остановлен: отключение не подтверждено'; return; }
        // VPN transport metadata can hide the underlying Wi-Fi/cellular network.
        // For failed candidates compare after teardown, before starting the next one.
        final afterVpn = await _network();
        if (cancelled()) return;
        if (!context.sameConnection(afterVpn)) { autoStatus = 'Сеть изменилась — запустите подбор заново'; return; }
        // An unknown launch/probe failure is not a negative server training label.
        if (!sameNetwork) await _remember(server, context, null, 'network_uncertain');
      }
      if (finalists.isNotEmpty) {
        finalists.sort((a, b) => _requiresSpeed ? b.speed.compareTo(a.speed) : b.utility.compareTo(a.utility));
        var restoreAttempt = 0;
        // One bounded retry per finalist, after trying the other known-good paths.
        for (final finalist in [...finalists, ...finalists]) {
          restoreAttempt++;
          if (cancelled()) return;
          if (!context.sameConnection(await _network())) { autoStatus = 'Сеть изменилась — восстановление VPN остановлено'; return; }
          autoStatus = 'Повторное подключение лучшего из ${finalists.length} проверенных вариантов'; _notify();
          await importProfile(finalist.server.profile, finalist.server.name, 'ИИ · финал', updateFilter: false);
          if (cancelled()) return;
          await connect(null);
          if (_localNetworkFailure) {
            autoStatus = 'Восстановление остановлено: ошибка выбора базовой сети';
            autoAttemptReports.add('Подготовка восстановления: ${message ?? "базовая сеть недоступна"}. Туннель не запускался.');
            return;
          }
          final deadline = DateTime.now().add(const Duration(seconds: 70));
          while (!cancelled() && (state == ConnectionState.connecting || _stopping) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
          autoAttemptReports.add('Восстановление $restoreAttempt · ${finalist.server.protocol} · ${message ?? connectionStage ?? 'Нет подробностей'}');
          if (state == ConnectionState.connected && (connectionVerified || (measuredBytesPerSecond ?? 0) > 0) && context.sameConnection(await _network())) {
            if (_selectionTarget != null || _requiresSpeed) connectionVerified = finalist.qualified && (measuredBytesPerSecond ?? 0) >= targetBytesPerSecond;
            autoStatus = connectionVerified
                ? 'Выбран лучший из ${finalists.length} измеренных вариантов · опыт: ${_selector.samples}'
                : 'Сохранён резервный VPN; скорость ниже цели или нестабильна. Можно повторить подбор позже.'; return;
          }
          if (_nativeNeedsStop) await disconnect();
          if (_nativeNeedsStop) return;
        }
      }
      _roundCanContinue = true;
      autoStatus = finalists.isNotEmpty
        ? 'Найдено ${finalists.length} рабочих вариантов, но повторное подключение не прошло проверку. Причины восстановления — в диагностике.'
        : 'Проверено $attempt вариантов: соединение с подходящей загрузкой не найдено. Результаты всех попыток — в диагностике.';
    } catch (error) { if(!cancelled()) autoStatus = 'Подбор остановлен: ${error is StateError ? error.message : error.runtimeType}. Подробности в диагностике.'; }
    finally {
      try { await store.saveAttempts('${DateTime.now().toIso8601String()}\n${autoAttemptReports.join('\n\n')}'); } catch (_) { }
      if (!_disposed) _notify(); }
  }
  final CandidateLab Function(ReserveCandidateHost)? _reserveLabFactory;
  final DateTime Function() _reserveNow;
  Future<void> checkReserve() => _watchReserve();
  bool reserveEnabled = false;
  String reserveStatus = 'Подготовка резерва выключена';
  final _handoverPolicy = HandoverPolicy();
  Timer? _reserveTimer;
  CandidateLab? _reserveLab;
  bool _reserveBusy = false;
  int _reserveEpoch = 0, _reserveCursor = 0;
  CandidateResult? _reserve;
  DateTime? _reserveTime, _reserveAttempt;
  NetworkContext? _reserveNetwork;
  void setReserveEnabled(bool value) {
    reserveEnabled = value;
    _cancelReserve();
    reserveStatus = value ? 'Ожидание активного VPN; Android: проверка пока приложение открыто' : 'Подготовка резерва выключена';
    _notify();
  }
  void _cancelReserve() {
    _handoverPolicy.resetEvidence();
    _reserveEpoch++; _reserveTimer?.cancel(); _reserveTimer=null;
    _reserve=null; _reserveTime=null; _reserveNetwork=null;
    unawaited(_reserveLab?.cancel().catchError((Object _) {}));
  }
  void _scheduleReserve() {
    if (!reserveEnabled || _disposed || !_foreground || autoSelecting || busy ||
        _reserveBusy || state != ConnectionState.connected || engine is! ReserveCandidateHost ||
        activeServer?.protocol == 'wireguard') {
      return;
    }
    _reserveTimer ??= Timer(const Duration(minutes: 2), () {
      _reserveTimer=null; unawaited(_watchReserve());
    });
  }
  Future<void> _watchReserve() async {
    if (_reserveBusy || busy || autoSelecting || _disposed || !reserveEnabled || !_foreground ||
        state != ConnectionState.connected || engine is! ReserveCandidateHost) {
      return;
    }
    _reserveBusy=true;
    final token=_reserveEpoch, session=_connectionEpoch;
    bool live() => !_disposed && reserveEnabled && _foreground && token==_reserveEpoch &&
      session==_connectionEpoch && !autoSelecting && !busy && state==ConnectionState.connected;
    try {
      final context=await _network();
      if (!live() || context.ambiguous || context.type=='offline') return;
      if (_reserveNetwork!=null && !_reserveNetwork!.sameConnection(context)) {
        _reserve=null; _reserveTime=null; _handoverPolicy.resetEvidence();
      }
      _reserveNetwork=context;
      final metered=context.metered!=false;
      if (!_handoverPolicy.reserveBytes(4194304,metered,_reserveNow())) {
        reserveStatus='Достигнут часовой лимит проверок; VPN сохранён'; return;
      }
      int? speed;
      try {
        final sample=await _probeTunnel();
        if ((sample?['delay'] as num? ?? -1)>=0) speed=(sample?['bytesPerSecond'] as num?)?.toInt();
      } catch (_) { /* Failed samples require repeated confirmation. */ }
      if (!live() || !context.sameConnection(await _network())) return;
      _handoverPolicy.observe(speed,targetBytesPerSecond,_reserveNow());
      measuredBytesPerSecond=speed; connectionVerified=(speed??0)>=targetBytesPerSecond;
      final degraded=_handoverPolicy.degraded(_reserveNow());
      final needsReserve=_reserve==null || _reserveNetwork?.sameConnection(context)!=true ||
          _reserveTime==null || _reserveNow().difference(_reserveTime!)>=const Duration(minutes:2);
      final maySearch=_reserveAttempt==null || _reserveNow().difference(_reserveAttempt!)>=Duration(minutes:degraded?2:10);
      if (needsReserve && maySearch && _handoverPolicy.reserveBytes(6291456,metered,_reserveNow())) {
        _reserveAttempt=_reserveNow();
        reserveStatus='Проверка запасного сервера; текущий VPN остаётся включён'; _notify();
        final catalog=await _catalogLoader();
        if (!live()) return;
        final candidates=PublicCatalog.diverse([..._imports,...catalog.servers].where((s)=>
          s.protocol!='wireguard' && s.profile!=activeServer?.profile &&
          _handoverPolicy.eligible(s.profile,_reserveNow()) &&
          (!_desktop || s.protocol!='vless' || ConnectionStrategy.protectedVless(s))).toList());
        if (candidates.isNotEmpty) {
          final start=_reserveCursor%candidates.length;
          final batch=[...candidates.skip(start),...candidates.take(start)].take(3).toList();
          _reserveCursor+=batch.length;
          final lab=_reserveLab ??= _reserveLabFactory?.call(engine as ReserveCandidateHost) ?? CandidateLab(ReserveHostAdapter(engine as ReserveCandidateHost));
          final results=await lab.run(batch,deep:false,metered:true,target:targetBytesPerSecond,
            policy:const SelectionPolicy(fastCandidates:3,fastSeconds:25),
            routeValid:() async {
              final current=await _network();
              return live() && !current.ambiguous && context.sameConnection(current);
            },status:(_){});
          if (!live()) return;
          final good=results.where((r)=>r.usable && r.speed>=targetBytesPerSecond).toList();
          _reserve=good.isEmpty?null:good.first; _reserveTime=_reserveNow(); _reserveNetwork=context;
        }
      }
      if (!live()) return;
      final candidate=_reserve, time=_reserveTime;
      if (candidate==null || time==null) { reserveStatus='Подходящий резерв не найден; текущий VPN сохранён'; return; }
      reserveStatus='Резерв проверен: ${(candidate.speed*8/1000000).toStringAsFixed(1)} Мбит/с; переключение только при устойчивом ухудшении';
      if (_handoverPolicy.canSwitch(profile:candidate.server.profile,speed:candidate.speed,current:speed??0,
          target:targetBytesPerSecond,measuredAt:time,now:_reserveNow()) && context.sameConnection(await _network()) && live()) {
        final previous=activeServer;
        if (previous==null) return;
        _handoverPolicy.beginSwitch(_reserveNow());
        autoSelecting=true;
        final watch=Stopwatch()..start();
        bool allowed()=>!_disposed && reserveEnabled && token==_reserveEpoch;
        Future<bool> activate(VpnServer server) async {
          try {
          if (!allowed() || !context.sameConnection(await _network())) return false;
          await disconnect(automatic:true);
          if (!allowed() || _nativeNeedsStop) return false;
          await importProfile(server.profile,server.name,'Резерв · ${server.source}',updateFilter:false);
          if (!allowed()) return false;
          await connect(null,automatic:true);
          final deadline=DateTime.now().add(const Duration(seconds:60));
          while (allowed() && (busy || _stopping || state==ConnectionState.connecting) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds:200));
          }
          return allowed() && state==ConnectionState.connected && connectionVerified &&
            context.sameConnection(await _network());
          } catch (_) { return false; }
        }
        try {
          reserveStatus='Переход на проверенный резерв'; _notify();
          final ok=await activate(candidate.server);
          if (!allowed()) return;
          if (ok) {reserveStatus='Переход подтверждён за ${watch.elapsed.inSeconds} с; пауза переключений 10 минут';}
          else {
            _handoverPolicy.failed(candidate.server.profile,_reserveNow());
            reserveStatus='Резерв не подтвердился; одна попытка возврата'; _notify();
            final restored=await activate(previous);
            if (!allowed()) return;
            reserveStatus=restored?'Возврат подтверждён; автоматические переходы на паузе':'Возврат не подтверждён; автоматические переходы остановлены';
            if (!restored) reserveEnabled=false;
          }
        } finally { autoSelecting=false; _reserve=null; _reserveTime=null; }
      }
    } catch (_) { reserveStatus='Резерв не подтверждён; повтор позже, текущий VPN не переключается'; }
    finally { _reserveBusy=false; if (!_disposed) {_notify(); _scheduleReserve();} }
  }

  String? reconnectAdvice;
  Timer? _healthTimer;
  void _scheduleHealthStatus() {
    _healthTimer?.cancel();
    if (_disposed || !_foreground || !Platform.isAndroid) return;
    _healthTimer = Timer(const Duration(seconds: 5), () async {
      try {
        final value = await const MethodChannel('quietvpn/quality-notification')
            .invokeMapMethod<String,dynamic>('status');
        if (_disposed) return;
        final text = value?['message'] as String?;
        reconnectAdvice = text == null || text.isEmpty ? null : text;
        if (reconnectAdvice != null) connectionVerified = false;
        _notify();
      } catch (_) { }
      if (!_disposed) _scheduleHealthStatus();
    });
  }
  Future<void> reconnectFromAdvice({bool findAnother = false}) async {
    if (busy || autoSelecting) return;
    await disconnect();
    if (_disposed || _nativeNeedsStop) return;
    if (findAnother) { await autoConnect(deep: true); }
    else { await connect(null); }
  }

  bool _foreground = true, _disposed = false, _nativeNeedsStop = false, _stopping = false;
  bool _localNetworkFailure = false;
  bool _verifying = false;
  bool _nativeConnected = false;
  String? _pendingFailure;
  bool get canDisconnect => _nativeNeedsStop;
  int _connectionEpoch = 0, _probeEpoch = 0;
  Timer? _poll, _connectTimeout, _trafficTimer;
  final traffic = TrafficMeter();
  final _clock = Stopwatch()..start();
  String? connectionStage;
  void _scheduleTraffic() {
    _trafficTimer?.cancel();
    final source = engine is TrafficSource ? engine as TrafficSource : null;
    if (_disposed || !_foreground || state != ConnectionState.connected || source == null) {
      traffic.reset(); return;
    }
    final epoch = _connectionEpoch;
    _trafficTimer = Timer(const Duration(seconds: 1), () async {
      TrafficCounters? counters;
      try { counters = await source.readTraffic().timeout(const Duration(seconds: 2)); } catch (_) { }
      if (_disposed || !_foreground || epoch != _connectionEpoch || state != ConnectionState.connected) return;
      if (counters == null) { traffic.reset(); } else { traffic.sample(counters, _clock.elapsed); }
      _notify(); _scheduleTraffic();
    });
  }
  StreamSubscription<EngineEvent>? _subscription;
  VpnServer? get selected {
    for (final server in servers) { if (server.id == selectedId) return server; }
    return null;
  }
  String? _qualityNoticeKey;
  void _notify() {
    if (_disposed) return;
    if (Platform.isAndroid) {
      final active = !autoSelecting && !_stopping && state == ConnectionState.connected;
      final speed = active ? measuredBytesPerSecond ?? 0 : 0;
      final key = '$active|$speed|$targetBytesPerSecond|$_connectionEpoch';
      if (key != _qualityNoticeKey) {
        _qualityNoticeKey = key;
        unawaited(const MethodChannel('quietvpn/quality-notification').invokeMethod<void>('update',
          {'active': active, 'speed': speed, 'target': targetBytesPerSecond}).catchError((Object _) { }));
      }
    }
    _scheduleReserve();
    notifyListeners();
  }

  Future<void> initialize() async {
    _subscription = engine.events.listen(_onEvent);
    try {
      _imports = await store.load();
      try { _selector = AdaptiveSelector.decode(await store.loadSelector()); } catch (_) { }
      try {
        final previous = await store.loadAttempts();
        if (previous != null && previous.isNotEmpty) autoAttemptReports.add('Предыдущий подбор (сохранённый отчёт):\n$previous');
      } catch (_) { }
      if(engine is CandidateHost) {
      try {
        final raw=await store.loadNetworkLab();
        if(raw!=null) _labStorage=Map<String,dynamic>.from(jsonDecode(raw) as Map);
        if(_labStorage['policy'] is String) _policy=SelectionPolicy.parse(_labStorage['policy'] as String);
        final context=await _network();
        for(final entry in _labStorage['analyses'] as List? ?? []) {
          final a=NetworkAnalysis.fromJson(Map<String,dynamic>.from(entry as Map));
          if(a.fresh(context,DateTime.now())) {networkAnalysis=a;analysisStatus=a.label;break;}
        }
      } catch(_) { }
      }
      await engine.initialize(); ready = true;
    } catch (_) { message = 'Не удалось инициализировать VPN или защищённое хранилище. На Windows проверьте установку и запуск от администратора.'; state = ConnectionState.error; }
    if (servers.isNotEmpty) selectedId = servers.first.id;
    _scheduleProbe(immediate: true); _scheduleBackgroundPreflight(immediate: true); _scheduleBaseline(immediate: true); _scheduleHealthStatus(); _notify();
  }
  void refreshLatency() {
    _probeEpoch++; monitor.cancel();
    _scheduleProbe(immediate: true);
  }
  void select(String id) { if (autoSelecting) return; selectedId = id; _notify(); }
  void filterProtocol(String? value) {
    protocolFilter = value; country = null;
    _probeEpoch++; monitor.cancel(); _scheduleProbe(immediate: true); _notify();
  }
  void filterCountry(String? value) {
    country = value; _probeEpoch++; monitor.cancel();
    _scheduleProbe(immediate: true); _notify();
  }
  void setForeground(bool visible) {
    if (_disposed || _foreground == visible) return;
    _foreground = visible;
    _scheduleHealthStatus();
    if (!visible) _cancelReserve();
    _baselineTimer?.cancel();
    if (visible) _scheduleBaseline(immediate: true);
    _backgroundTimer?.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    if (!visible) _networkAnalyzer.cancel();
    if (!visible && autoSelecting && !requestingNetworkPermission) {
      unawaited(cancelAutoSelection(reason: 'Подбор остановлен: приложение ушло в фон'));
    }
    _scheduleTraffic();
    _probeEpoch++; monitor.cancel(); _poll?.cancel();
    if (visible) {
      unawaited(engine.reconcile().catchError((Object _) { message = 'Не удалось сверить состояние VPN'; _notify(); }));
      _scheduleProbe(immediate: true);
      _scheduleBackgroundPreflight(immediate: true);
    } else {
      health = {for (final s in servers) s.id: const HealthResult(Reachability.paused)};
      _notify();
    }
    // Android native foreground service owns the tunnel; Dart timers are not
    // used as a guarantee of background execution or kept alive with wake locks.
  }
  void _scheduleBackgroundPreflight({bool immediate = false}) {
    _backgroundTimer?.cancel();
    if (!_foreground || _disposed || autoSelecting || _nativeNeedsStop || state == ConnectionState.connected) return;
    final token = ++_backgroundEpoch;
    _backgroundTimer = Timer(Duration(seconds: immediate ? 3 : 120), () async {
      try {
        final context = await _network();
        if (token != _backgroundEpoch || context.type == 'offline' || autoSelecting || _nativeNeedsStop) return;
        final catalog = await _catalogLoader();
        if (token != _backgroundEpoch || autoSelecting || _nativeNeedsStop) return;
        final pool = [..._imports, ...catalog.servers].where((s) =>
        !_searchVisited.contains(ConnectionStrategy.profileKey(s)) &&
        (!_desktop || s.protocol != 'vless' || ConnectionStrategy.protectedVless(s))).toList();
      autoAttemptReports.add('База: ${catalog.status}\n'
        '${['wireguard', 'vless', 'shadowsocks'].map((p) => '$p: ${pool.where((s) => s.protocol == p).length} профилей').join('; ')}');
        final candidates = <VpnServer>[];
        for (final protocol in ['wireguard', 'vless', 'shadowsocks']) {
          final group = pool.where((server) => server.protocol == protocol).toList()
            ..sort((a, b) {
              final priority = _selector.recentPriority(b, context).compareTo(_selector.recentPriority(a, context));
              return priority != 0 ? priority : _selector.recentSpeed(b, context).compareTo(_selector.recentSpeed(a, context));
            });
          candidates.addAll(PublicCatalog.diverse(group, limit: protocol == 'wireguard' ? 8 : 24));
        }
        backgroundStatus = 'Фоновая проверка ${candidates.length} адресов…'; _notify();
        final measured = await _backgroundMonitor.sample(candidates);
        if (token != _backgroundEpoch || autoSelecting || _nativeNeedsStop) return;
        _backgroundHealth = measured; _backgroundContext = context; _backgroundMeasuredAt = DateTime.now();
        final reachable = measured.values.where((value) => value.state == Reachability.reachable).length;
        backgroundStatus = 'Фоновая проверка: доступно $reachable из ${measured.length}; свежие данные будут использованы при подборе';
        _notify();
      } catch (_) {
        if (token == _backgroundEpoch) backgroundStatus = 'Фоновая проверка адресов временно недоступна';
      } finally {
        if (token == _backgroundEpoch && !_disposed) _scheduleBackgroundPreflight();
      }
    });
  }
  void _scheduleProbe({bool immediate = false}) {
    _poll?.cancel();
    if (!_foreground || _disposed || autoSelecting) return;
    _poll = Timer(Duration(milliseconds: immediate ? 0 : 30000 + Random().nextInt(3000)), () async {
      final epoch = _probeEpoch;
      final results = await monitor.sample(servers, onResult: (id, result) {
        if (!_disposed && epoch == _probeEpoch && _foreground) {
          health[id] = result; _notify();
        }
      });
      if (_disposed) return;
      if (epoch == _probeEpoch && _foreground) { health = {...health, ...results}; _notify(); }
      if (epoch == _probeEpoch) _scheduleProbe();
    });
  }
  Future<void> importProfile(String text, String name, String region, {bool updateFilter = true}) async {
    final parsed = ProfilePolicy.parse(text);
    final id = 'local-${sha256.convert(utf8.encode(parsed.text)).toString().substring(0, 24)}';
    final server = VpnServer(id: id, name: name, country: region.isEmpty ? 'Мои профили' : region,
      countryCode: '--', host: parsed.host, port: parsed.port, transport: parsed.transport,
      profile: parsed.text, source: 'Импорт', protocol: parsed.protocol);
    final updated = [..._imports.where((s) => s.id != id), server];
    await store.save(updated);
    _imports = updated; selectedId = id; country = null;
    if (updateFilter) protocolFilter = parsed.protocol;
    message = '${parsed.protocol} профиль импортирован'; _scheduleProbe(immediate: true); _notify();
  }
  Future<void> removeSelected() async {
    final server = selected;
    if (autoSelecting || server == null || server.source != 'Импорт' || activeServer?.id == server.id) return;
    final updated = _imports.where((s) => s.id != server.id).toList();
    await store.save(updated); await store.removeCredentials(server.id);
    _imports = updated; selectedId = servers.isEmpty ? null : servers.first.id; _notify();
  }
  Future<void> connect(Credentials? credentials, {bool automatic=false}) async {
    if (!automatic) _cancelReserve();
    final server = selected;
    if (!ready || busy || _stopping || _nativeNeedsStop || server == null) return;
    _backgroundTimer?.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    backgroundStatus = null; busy = true; message = null; _localNetworkFailure = false; _notify();
    try {
      if(!autoSelecting && engine is CandidateHost) {
        final context=await _network();networkContext=context;
        _selectionTarget=baseline?.fresh(context,DateTime.now())==true?baseline!.target:null;
      }
      _networkAnalyzer.cancel();
      await _analysisPending;
      await _candidateLab?.cancel();
      await _baselineMonitor.pause(true);
      final parsed = ProfilePolicy.parse(server.profile);
      final auth = credentials ?? await store.credentials(server.id);
      if (parsed.needsAuth && auth == null) throw StateError('Укажите логин и пароль профиля');
      if (credentials != null) await store.saveCredentials(server.id, credentials);
      _nativeNeedsStop = true; activeServer = server;
      state = ConnectionState.connecting;
      connectionVerified = false; measuredBytesPerSecond = null;
      traffic.reset(); connectionStage = 'Запуск VPN';
      _connectionEpoch++;
      _connectTimeout?.cancel();
      _connectTimeout = Timer(Duration(seconds: autoSelecting ? (activeServer?.protocol == 'wireguard' ? 20 : 60) : (activeServer?.protocol == 'wireguard' ? 50 : 100)), () {
        if (state == ConnectionState.connecting) {
          unawaited(_fail('Таймаут: ${connectionStage ?? 'нет ответа'}. Попробуйте другой сервер или транспорт.'));
        }
      });
      _notify();
      await engine.connect(server, auth);
    } catch (error) {
      _localNetworkFailure = error is PlatformException && error.code == 'BASE_NETWORK';
      await _fail(error is StateError ? error.message.toString()
        : error is PlatformException ? (error.message ?? 'Не удалось запустить VPN')
        : 'Не удалось запустить VPN');
    } finally {
      busy = false;
      final failure = _pendingFailure;
      _pendingFailure = null;
      if (failure != null) await _fail(failure);
      _notify();
    }
  }
  void _onEvent(EngineEvent event) {
    if (_disposed || _stopping) return;
    switch (event.state) {
      case ConnectionState.connected:
        _connectTimeout?.cancel(); _connectTimeout = null;
        _nativeConnected = true;
        _nativeNeedsStop = true;
        if (engine is DesktopCapabilities || activeServer?.protocol == 'vless' || activeServer?.protocol == 'shadowsocks') {
          connectionVerified = _requiresSpeed ? (event.bytesPerSecond ?? 0) >= targetBytesPerSecond : event.quality; measuredBytesPerSecond = event.bytesPerSecond;
          state = ConnectionState.connected; message = event.message ?? 'Xray: ответ через сервер получен';
          _scheduleTraffic(); _notify();
        } else if (!_verifying && state != ConnectionState.connected) { unawaited(_verifyInternet()); }
      case ConnectionState.connecting:
        connectionVerified = false; measuredBytesPerSecond = null;
        _nativeConnected = false;
        connectionStage = event.message ?? connectionStage;
        message = connectionStage; traffic.reset(); _trafficTimer?.cancel();
        _nativeNeedsStop = true;
        if (state == ConnectionState.connected || _verifying) {
          _connectionEpoch++;
        }
        state = ConnectionState.connecting;
        _connectTimeout ??= Timer(Duration(seconds: autoSelecting ? (activeServer?.protocol == 'wireguard' ? 20 : 60) : (activeServer?.protocol == 'wireguard' ? 50 : 100)), () { unawaited(_fail('Таймаут VPN')); });
        _notify();
      case ConnectionState.disconnected:
        _nativeConnected = false;
        if (busy && _nativeNeedsStop) {
          _pendingFailure = 'Система закрыла VPN-соединение'; return;
        }
        final wasActive = _nativeNeedsStop;
        if (wasActive) {
          unawaited(_fail('Система закрыла VPN-соединение'));
          return;
        }
        _nativeNeedsStop = false; activeServer = null;
        _connectionEpoch++; _connectTimeout?.cancel(); _connectTimeout = null;
        state = ConnectionState.disconnected; _clearConfirmation();
        _notify();
      case ConnectionState.error:
        unawaited(_fail(event.message ?? 'Ошибка VPN'));
    }
  }

  Future<Map<String, dynamic>?> _probeTunnel() => engine is DesktopCapabilities
    ? (engine as DesktopCapabilities).probeTunnel().timeout(const Duration(seconds: 35))
    : const MethodChannel('quietvpn/xray-state').invokeMapMethod<String, dynamic>('tunnelProbe').timeout(const Duration(seconds: 30));

  Future<void> _verifyInternet() async {
    _verifying = true;
    final epoch = _connectionEpoch;
    try {
      final result = await _probeTunnel();
      if ((result?['delay'] as num? ?? -1) < 0) throw const HttpException('System VPN check failed');
      if (!_disposed && epoch == _connectionEpoch && _nativeNeedsStop) {
        _connectTimeout?.cancel(); _connectTimeout = null; state = ConnectionState.connected;
        measuredBytesPerSecond = (result?['bytesPerSecond'] as num?)?.toInt();
        connectionVerified = _requiresSpeed ? (measuredBytesPerSecond ?? 0)>=targetBytesPerSecond : result?['quality'] == true;
        message = '${result?['detail'] ?? 'HTTPS-проверка пройдена'}'; _scheduleTraffic(); _notify();
      }
    } catch (_) {
      if (!_disposed && epoch == _connectionEpoch && !_stopping && _nativeConnected && _nativeNeedsStop) {
        _connectTimeout?.cancel(); _connectTimeout = null; state = ConnectionState.connected;
        message = 'Туннель подключён. Доступ в интернет не подтверждён: HTTPS-проверка не прошла.';
        _scheduleTraffic(); _notify();
      }
    } finally {
      _verifying = false;
      if (!_disposed && !_stopping && _nativeConnected && _nativeNeedsStop &&
          epoch != _connectionEpoch && state == ConnectionState.connecting) {
        unawaited(_verifyInternet());
      }
    }
  }
  void _clearConfirmation() {
    connectionVerified = false; measuredBytesPerSecond = null; connectionStage = null;
  }
  Future<void> _fail(String reason) async {
    if (_stopping || _disposed) return;
    if (busy) { _pendingFailure = reason; return; }
    if (!autoSelecting && state == ConnectionState.connected) {
      reconnectAdvice = 'Соединение потеряно. Переподключитесь или подберите другой сервер.';
      if (Platform.isAndroid) {
        unawaited(const MethodChannel('quietvpn/quality-notification')
            .invokeMethod<void>('reportDrop').catchError((Object _) {}));
      }
    }
    _clearConfirmation();
    traffic.reset(); _trafficTimer?.cancel();
    _stopping = true; _nativeConnected = false; _connectionEpoch++; _connectTimeout?.cancel(); _connectTimeout = null;
    try {
      if (_nativeNeedsStop) await engine.disconnect();
      _nativeNeedsStop = false; activeServer = null;
      if (!autoSelecting) await _baselineMonitor.pause(false);
      message = reason;
    } catch (_) { message = '$reason Отключение не подтверждено — повторите его.'; }
    finally { _stopping = false; state = ConnectionState.error; _notify(); }
  }
  Future<void> disconnect({bool automatic=false}) async {
    if (!automatic) _cancelReserve();
    if (busy || _stopping) return;
    reconnectAdvice = null;
    _clearConfirmation();
    traffic.reset(); _trafficTimer?.cancel();
    busy = true; _stopping = true; _nativeConnected = false; _connectionEpoch++;
    _connectTimeout?.cancel(); _connectTimeout = null; _notify();
    try {
      if (Platform.isAndroid) {
        try { await const MethodChannel('quietvpn/quality-notification').invokeMethod<void>('stop'); } catch (_) { }
      }
      await engine.disconnect(); _nativeNeedsStop = false; activeServer = null;
      if (!autoSelecting) await _baselineMonitor.pause(false);
      state = ConnectionState.disconnected; message = null;
    } catch (_) { state = ConnectionState.error; message = 'Отключение не подтверждено. Повторите или используйте настройки системы.'; }
    finally {
      busy = false; _stopping = false; _scheduleBackgroundPreflight(immediate: true);
      if(!autoSelecting && !_nativeNeedsStop) _scheduleBaseline(immediate:true,forceAnalysis:true);
      _notify();
    }
  }
  @override void dispose() {
    _cancelReserve();
    _networkAnalyzer.cancel();unawaited(_candidateLab?.cancel());
    _healthTimer?.cancel();
    _baselineTimer?.cancel(); _baselineMonitor.dispose();
    _disposed = true; _autoEpoch++; _autoMonitor.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    _backgroundTimer?.cancel(); _trafficTimer?.cancel(); _poll?.cancel(); _connectTimeout?.cancel();
    monitor.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

