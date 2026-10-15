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
import '../core/network_context.dart';
import '../core/network_baseline.dart';
import '../platform/vpn_engine.dart';
import '../platform/desktop_capabilities.dart';

class VpnViewModel extends ChangeNotifier {
  VpnViewModel(this.engine, this.store, this.monitor, {
    Future<PublicCatalogResult> Function()? catalogLoader,
    Future<String> Function()? networkReader, ServerMonitor? autoMonitor, ServerMonitor? backgroundMonitor,
  }) : _catalogLoader = catalogLoader ?? PublicCatalog().load,
       _networkReader = networkReader, _autoMonitor = autoMonitor ?? ServerMonitor(),
       _backgroundMonitor = backgroundMonitor ?? ServerMonitor();
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
  final _baselineMonitor = BaselineMonitor();
  Timer? _baselineTimer;
  NetworkBaseline? baseline;
  String baselineStatus = 'Наблюдение за вашей сетью: ожидание замера без VPN';
  int? _selectionTarget;
  int get targetBytesPerSecond => _selectionTarget ?? 131072;
  void _scheduleBaseline({bool immediate = false}) {
    _baselineTimer?.cancel();
    if (_disposed || !ready || (!Platform.isWindows && !_foreground)) return;
    _baselineTimer = Timer(Duration(seconds: immediate ? 1 : 30), () async {
      try {
        if (!autoSelecting && !_nativeNeedsStop && !busy) {
          final context = await _network();
          if (_disposed || autoSelecting || _nativeNeedsStop || busy) return;
          networkContext = context;
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
    _autoEpoch++; _autoMonitor.cancel(); autoStatus = reason; _notify();
    if (!busy && _nativeNeedsStop) await disconnect();
  }
  Future<void> autoConnect({bool deep = false}) async {
    if (!ready || busy || autoSelecting || _nativeNeedsStop || _stopping) return;
    autoSelecting = true; final token = ++_autoEpoch;
    autoAttemptReports.clear();
    autoPlan = ''; protocolFilter = null; country = null;
    autoStatus = 'Локальная нейросеть: обновление базы'; _notify();
    _poll?.cancel(); _probeEpoch++; monitor.cancel();
    _backgroundTimer?.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    bool cancelled() => token != _autoEpoch || _disposed;
    try {
      final context = await _network();
      networkContext = context;
      _selectionTarget = baseline?.fresh(context, DateTime.now()) == true ? baseline!.target : null;
      await _baselineMonitor.pause(true);
      final network = context.type;
      if (cancelled()) return;
      if (network == 'offline') { autoStatus = 'Нет доступной сети'; return; }
      final catalog = await _catalogLoader();
      if (cancelled()) return;
      final pool = [..._imports, ...catalog.servers];
      int rank(VpnServer a, VpnServer b, Map<String, HealthResult>? latency) {
        final recent = _selector.recentPriority(b, context).compareTo(_selector.recentPriority(a, context));
        if (recent != 0) return recent;
        final speed = _selector.recentSpeed(b, context).compareTo(_selector.recentSpeed(a, context));
        if (speed != 0) return speed;
        final score = _selector.score(b, network, latency?[b.id]?.milliseconds, context: context)
          .compareTo(_selector.score(a, network, latency?[a.id]?.milliseconds, context: context));
        if (score != 0) return score;
        // Untested UDP is not known-bad, but avoid spending the first 20s on it.
        return (a.protocol == 'wireguard' ? 1 : 0).compareTo(b.protocol == 'wireguard' ? 1 : 0);
      }
      // A small diverse shortlist avoids launching hundreds of ping processes.
      final candidates = <VpnServer>[];
      final hosts = <String>{};
      for (final protocol in ['wireguard', 'vless', 'shadowsocks']) {
        final group = pool.where((s) => s.protocol == protocol).toList()
          ..sort((a, b) => rank(a, b, null));
        var count = 0;
        for (final server in group) {
          if (count >= 8) break;
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
      if (missing.isNotEmpty) latency.addAll(await _autoMonitor.sample(missing));
      if (cancelled()) return;
      candidates.sort((a, b) => rank(a, b, latency));
      final ordered = AdaptiveSelector.shortlist(candidates, limit: deep ? 8 : 6);
      // Preserve protocol diversity within each retry tier, but do not force a
      // recent failure ahead of an untried or recently verified profile.
      final tiered = [for (final tier in [1, 0, -1])
        ...ordered.where((s) => _selector.recentPriority(s, context) == tier)];
      ordered..clear()..addAll(tiered);
      final finalists = <({VpnServer server, double utility})>[];
      autoPlan = '${_selectionTarget == null ? '' : 'Цель сети: ${(targetBytesPerSecond * 8 / 1000000).toStringAsFixed(1)} Мбит/с · '}${deep ? 'Глубокий' : 'Быстрый'} подбор · план: ${ordered.map((s) => s.protocol).join(' → ')}';
      autoAttemptReports.add('База: ${catalog.status}\n'
        '${['wireguard', 'vless', 'shadowsocks'].map((p) => '$p: ${pool.where((s) => s.protocol == p).length} профилей').join('; ')}\n$autoPlan');
      final searchClock = Stopwatch()..start();
      final budget = Duration(seconds: deep ? 300 : 150);
      final protocolFailures = <String, int>{};
      var attempt = 0;
      for (final server in ordered) {
        if (cancelled()) return;
        if (searchClock.elapsed >= budget || (deep && finalists.length >= 2)) break;
        if ((protocolFailures[server.protocol] ?? 0) >= 2) {
          autoAttemptReports.add('${server.protocol}: пропуск после двух неподтверждённых попыток в этом подборе');
          continue;
        }
        if (!context.sameConnection(await _network())) { autoStatus = 'Сеть изменилась — запустите подбор заново'; return; }
        if (cancelled()) return;
        attempt++;
        autoStatus = 'ИИ-подбор: попытка $attempt/${ordered.length} · ${server.protocol} · подключение и проверка'; _notify();
        await importProfile(server.profile, server.name, 'ИИ-подбор · ${server.source}', updateFilter: false);
        if (cancelled()) return;
        await connect(null);
        final deadline = DateTime.now().add(const Duration(seconds: 70));
        while (!cancelled() && (state == ConnectionState.connecting || _stopping) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        final duringVpn = await _network();
        final sameNetwork = context.sameConnection(duringVpn);
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        var success = state == ConnectionState.connected && connectionVerified;
        if (_selectionTarget != null) {
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
          success = !repeatFailed && speeds.length == 3 && speeds.first >= targetBytesPerSecond;
        }
        final medianSpeed = speeds.isEmpty ? null : speeds[speeds.length ~/ 2];
        final usable = state == ConnectionState.connected && !repeatFailed &&
            medianSpeed != null && medianSpeed > 0 && sameNetwork;
        if (sameNetwork) {
          protocolFailures[server.protocol] = usable || success ? 0 : (protocolFailures[server.protocol] ?? 0) + 1;
        }
        // Short repeated downloads measure consistency, not long-session stability.
        final utility = medianSpeed == null ? 0.0 :
          (.75 * (medianSpeed / (medianSpeed + 524288)) +
           .25 * (speeds.first / max(1, speeds.last))).toDouble();
        final attemptResult = success ? 'успех' : usable ? 'работает, ниже цели' : 'не подтверждено';
        autoAttemptReports.add('Попытка $attempt · ${server.protocol} · $attemptResult\n${message ?? connectionStage ?? 'Нет подробностей'}');
        if (sameNetwork && !context.ambiguous && !duringVpn.ambiguous) {
          await _remember(server, context, latency[server.id]?.milliseconds,
            success ? 'verified' : usable ? 'usable' : medianSpeed != null ? 'slow_or_unstable' : 'unconfirmed',
            speed: medianSpeed, reward: medianSpeed == null || repeatFailed ? null : .2 + .8 * utility);
        }
        if (usable && !context.ambiguous) {
          finalists.add((server: server, utility: utility));
          autoAttemptReports.add('${speeds.length} замер(а): ${speeds.map((n) => '${(n / 1024).round()} КиБ/с').join(', ')}');
        }
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        if (!deep && (success || (usable && _selectionTarget == null)) && sameNetwork) {
          connectionVerified = success;
          autoStatus = success
            ? 'ИИ выбрал соединение с подтверждённым HTTPS · опыт: ${_selector.samples}'
            : 'ИИ сохранил первый рабочий VPN; скорость ниже цели. Глубокий подбор может найти быстрее.';
          return;
        }
        // Keep the best live tunnel when comparison is complete: reconnecting
        // a public endpoint can fail even immediately after a successful sample.
        final comparisonDone = finalists.length >= 2 || server == ordered.last || searchClock.elapsed >= budget;
        if (deep && usable && !context.ambiguous && comparisonDone &&
            finalists.every((candidate) => candidate.utility <= utility)) {
          connectionVerified = success;
          measuredBytesPerSecond = medianSpeed;
          autoStatus = success ? 'Сохранён лучший из ${finalists.length} измеренных вариантов без переподключения'
            : 'Сохранён рабочий резервный VPN; скорость ниже целевой.';
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
        finalists.sort((a, b) => b.utility.compareTo(a.utility));
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
          final deadline = DateTime.now().add(const Duration(seconds: 70));
          while (!cancelled() && (state == ConnectionState.connecting || _stopping) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
          autoAttemptReports.add('Восстановление $restoreAttempt · ${finalist.server.protocol} · ${message ?? connectionStage ?? 'Нет подробностей'}');
          if (state == ConnectionState.connected && (connectionVerified || (measuredBytesPerSecond ?? 0) > 0) && context.sameConnection(await _network())) {
            if (_selectionTarget != null) connectionVerified = (measuredBytesPerSecond ?? 0) >= targetBytesPerSecond;
            autoStatus = connectionVerified
                ? 'Выбран лучший из ${finalists.length} измеренных вариантов · опыт: ${_selector.samples}'
                : 'Сохранён рабочий резервный VPN; скорость ниже целевой. Можно повторить подбор позже.'; return;
          }
          if (_nativeNeedsStop) await disconnect();
          if (_nativeNeedsStop) return;
        }
      }
      autoStatus = finalists.isNotEmpty
        ? 'Найдено ${finalists.length} рабочих вариантов, но повторное подключение не прошло проверку. Причины восстановления — в диагностике.'
        : 'Проверено $attempt вариантов: соединение с подходящей загрузкой не найдено. Результаты всех попыток — в диагностике.';
    } catch (_) { autoStatus = 'Подбор не завершён. Проверьте сеть и диагностику.'; }
    finally {
      try { await store.saveAttempts('${DateTime.now().toIso8601String()}\n${autoAttemptReports.join('\n\n')}'); } catch (_) { }
      autoSelecting = false; if (!_disposed) { _scheduleProbe(); _scheduleBackgroundPreflight(); _scheduleBaseline(immediate: true); _notify(); } }
  }
  bool _foreground = true, _disposed = false, _nativeNeedsStop = false, _stopping = false;
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
  void _notify() { if (!_disposed) notifyListeners(); }

  Future<void> initialize() async {
    _subscription = engine.events.listen(_onEvent);
    try {
      _imports = await store.load();
      try { _selector = AdaptiveSelector.decode(await store.loadSelector()); } catch (_) { }
      try {
        final previous = await store.loadAttempts();
        if (previous != null && previous.isNotEmpty) autoAttemptReports.add('Предыдущий подбор (сохранённый отчёт):\n$previous');
      } catch (_) { }
      await engine.initialize(); ready = true;
    } catch (_) { message = 'Не удалось инициализировать VPN или защищённое хранилище. На Windows проверьте установку и запуск от администратора.'; state = ConnectionState.error; }
    if (servers.isNotEmpty) selectedId = servers.first.id;
    _scheduleProbe(immediate: true); _scheduleBackgroundPreflight(immediate: true); _scheduleBaseline(immediate: true); _notify();
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
    _baselineTimer?.cancel();
    if (visible) _scheduleBaseline(immediate: true);
    _backgroundTimer?.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
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
        final pool = [..._imports, ...catalog.servers];
        final candidates = <VpnServer>[];
        for (final protocol in ['wireguard', 'vless', 'shadowsocks']) {
          final group = pool.where((server) => server.protocol == protocol).toList()
            ..sort((a, b) {
              final priority = _selector.recentPriority(b, context).compareTo(_selector.recentPriority(a, context));
              return priority != 0 ? priority : _selector.recentSpeed(b, context).compareTo(_selector.recentSpeed(a, context));
            });
          candidates.addAll(group.take(8));
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
  Future<void> connect(Credentials? credentials) async {
    final server = selected;
    if (!ready || busy || _stopping || _nativeNeedsStop || server == null) return;
    _backgroundTimer?.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    backgroundStatus = null; busy = true; message = null; _notify();
    try {
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
          connectionVerified = event.quality; measuredBytesPerSecond = event.bytesPerSecond;
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
        connectionVerified = result?['quality'] == true; measuredBytesPerSecond = (result?['bytesPerSecond'] as num?)?.toInt();
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
  Future<void> disconnect() async {
    if (busy || _stopping) return;
    _clearConfirmation();
    traffic.reset(); _trafficTimer?.cancel();
    busy = true; _stopping = true; _nativeConnected = false; _connectionEpoch++;
    _connectTimeout?.cancel(); _connectTimeout = null; _notify();
    try {
      await engine.disconnect(); _nativeNeedsStop = false; activeServer = null;
      if (!autoSelecting) await _baselineMonitor.pause(false);
      state = ConnectionState.disconnected; message = null;
    } catch (_) { state = ConnectionState.error; message = 'Отключение не подтверждено. Повторите или используйте настройки системы.'; }
    finally { busy = false; _stopping = false; _scheduleBackgroundPreflight(immediate: true); _notify(); }
  }
  @override void dispose() {
    _baselineTimer?.cancel(); _baselineMonitor.dispose();
    _disposed = true; _autoEpoch++; _autoMonitor.cancel(); _backgroundEpoch++; _backgroundMonitor.cancel();
    _backgroundTimer?.cancel(); _trafficTimer?.cancel(); _poll?.cancel(); _connectTimeout?.cancel();
    monitor.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

