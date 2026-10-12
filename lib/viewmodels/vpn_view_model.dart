import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/traffic.dart';
import '../core/profile_policy.dart';
import '../core/server_monitor.dart';
import '../data/profile_store.dart';
import '../data/public_catalog.dart';
import '../core/adaptive_selector.dart';
import '../core/network_context.dart';
import '../platform/vpn_engine.dart';

class VpnViewModel extends ChangeNotifier {
  VpnViewModel(this.engine, this.store, this.monitor, {
    Future<PublicCatalogResult> Function()? catalogLoader,
    Future<String> Function()? networkReader, ServerMonitor? autoMonitor,
  }) : _catalogLoader = catalogLoader ?? PublicCatalog().load,
       _networkReader = networkReader, _autoMonitor = autoMonitor ?? ServerMonitor();
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
  static const _networkChannel = MethodChannel('quietvpn/catalog-cache');
  NetworkContext networkContext = const NetworkContext();
  final List<String> autoAttemptReports = [];
  String autoPlan = '';
  Future<NetworkContext> _network() async {
    if (_networkReader != null) return NetworkContext(type: await _networkReader());
    try {
      final data = await _networkChannel.invokeMapMethod<dynamic, dynamic>('networkContext');
      return NetworkContext.fromMap(data ?? {});
    } catch (_) { return const NetworkContext(); }
  }
  Future<void> cancelAutoSelection() async {
    _autoEpoch++; _autoMonitor.cancel(); autoStatus = 'Подбор остановлен'; _notify();
    if (!busy && _nativeNeedsStop) await disconnect();
  }
  Future<void> autoConnect() async {
    if (!ready || busy || autoSelecting || _nativeNeedsStop || _stopping) return;
    autoSelecting = true; final token = ++_autoEpoch;
    autoAttemptReports.clear();
    autoPlan = ''; protocolFilter = null; country = null;
    autoStatus = 'Локальная нейросеть: обновление базы'; _notify();
    _poll?.cancel(); _probeEpoch++; monitor.cancel();
    bool cancelled() => token != _autoEpoch || _disposed;
    try {
      final context = await _network();
      networkContext = context;
      final network = context.type;
      if (cancelled()) return;
      if (network == 'offline') { autoStatus = 'Нет доступной сети'; return; }
      final catalog = await _catalogLoader();
      if (cancelled()) return;
      final pool = [..._imports, ...catalog.servers];
      // A small diverse shortlist avoids launching hundreds of ping processes.
      final candidates = <VpnServer>[];
      final hosts = <String>{};
      for (final protocol in ['wireguard', 'vless', 'shadowsocks']) {
        final group = pool.where((s) => s.protocol == protocol).toList()
          ..sort((a, b) => _selector.score(b, network, null, context: context).compareTo(_selector.score(a, network, null, context: context)));
        var count = 0;
        for (final server in group) {
          if (count >= 8) break;
          if (hosts.add('$protocol|${server.host}')) { candidates.add(server); count++; }
        }
      }
      autoStatus = 'Сеть: ${context.label} · оценка ${candidates.length} адресов · опыт: ${_selector.samples}'; _notify();
      final latency = await _autoMonitor.sample(candidates);
      if (cancelled()) return;
      candidates.sort((a, b) => _selector.score(b, network, latency[b.id]?.milliseconds, context: context)
        .compareTo(_selector.score(a, network, latency[a.id]?.milliseconds, context: context)));
      final ordered = AdaptiveSelector.shortlist(candidates);
      autoPlan = 'План: ${ordered.map((s) => s.protocol).join(' → ')}';
      autoAttemptReports.add('База: ${catalog.status}\n'
        '${['wireguard', 'vless', 'shadowsocks'].map((p) => '$p: ${pool.where((s) => s.protocol == p).length} профилей').join('; ')}\n$autoPlan');
      var attempt = 0;
      for (final server in ordered.take(6)) {
        if (cancelled()) return;
        if (!context.sameConnection(await _network())) { autoStatus = 'Сеть изменилась — запустите подбор заново'; return; }
        if (cancelled()) return;
        attempt++;
        autoStatus = 'ИИ-подбор: попытка $attempt/${ordered.length} · ${server.protocol} · проверка HTTPS'; _notify();
        await importProfile(server.profile, server.name, 'ИИ-подбор · ${server.source}', updateFilter: false);
        if (cancelled()) return;
        await connect(null);
        final deadline = DateTime.now().add(const Duration(seconds: 110));
        while (!cancelled() && (state == ConnectionState.connecting || _stopping) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        final duringVpn = await _network();
        final sameNetwork = context.sameConnection(duringVpn);
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        final success = state == ConnectionState.connected && connectionVerified;
        autoAttemptReports.add('Попытка $attempt · ${server.protocol} · ${success ? 'успех' : 'не подтверждено'}\n${message ?? connectionStage ?? 'Нет подробностей'}');
        if (success && sameNetwork && !context.ambiguous && !duringVpn.ambiguous) {
          _selector.observe(server, network, latency[server.id]?.milliseconds, success: true, context: context);
          try { await store.saveSelector(_selector.encode()); } catch (_) { }
        }
        if (cancelled()) { if (_nativeNeedsStop) await disconnect(); return; }
        if (success && sameNetwork) { autoStatus = 'ИИ выбрал соединение с подтверждённым HTTPS · опыт: ${_selector.samples}'; return; }
        final failure = message;
        if (_nativeNeedsStop) await disconnect();
        message = failure;
        if (_nativeNeedsStop) { autoStatus = 'Подбор остановлен: отключение не подтверждено'; return; }
        // VPN transport metadata can hide the underlying Wi-Fi/cellular network.
        // For failed candidates compare after teardown, before starting the next one.
        final afterVpn = await _network();
        if (cancelled()) return;
        if (!context.sameConnection(afterVpn)) { autoStatus = 'Сеть изменилась — запустите подбор заново'; return; }
        if (!success && !context.ambiguous && !afterVpn.ambiguous) {
          _selector.observe(server, network, latency[server.id]?.milliseconds, success: false, context: context);
          try { await store.saveSelector(_selector.encode()); } catch (_) { }
        }
      }
      autoStatus = 'Проверено $attempt вариантов: соединение с подходящей загрузкой не найдено. Результаты всех попыток — в диагностике.';
    } catch (_) { autoStatus = 'Подбор не завершён. Проверьте сеть и диагностику.'; }
    finally { autoSelecting = false; if (!_disposed) { _scheduleProbe(); _notify(); } }
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
      await engine.initialize(); ready = true;
    } catch (_) { message = 'Не удалось инициализировать VPN или защищённое хранилище'; state = ConnectionState.error; }
    if (servers.isNotEmpty) selectedId = servers.first.id;
    _scheduleProbe(immediate: true); _notify();
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
    _foreground = visible;
    if (!visible && autoSelecting) unawaited(cancelAutoSelection());
    _scheduleTraffic();
    _probeEpoch++; monitor.cancel(); _poll?.cancel();
    if (visible) {
      unawaited(engine.reconcile().catchError((Object _) { message = 'Не удалось сверить состояние VPN'; _notify(); }));
      _scheduleProbe(immediate: true);
    } else {
      health = {for (final s in servers) s.id: const HealthResult(Reachability.paused)};
      _notify();
    }
    // Android native foreground service owns the tunnel; Dart timers are not
    // used as a guarantee of background execution or kept alive with wake locks.
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
    busy = true; message = null; _notify();
    try {
      final parsed = ProfilePolicy.parse(server.profile);
      final auth = credentials ?? await store.credentials(server.id);
      if (parsed.needsAuth && auth == null) throw StateError('Укажите логин и пароль профиля');
      if (credentials != null) await store.saveCredentials(server.id, credentials);
      _nativeNeedsStop = true; activeServer = server;
      state = ConnectionState.connecting;
      connectionVerified = false;
      traffic.reset(); connectionStage = 'Запуск VPN';
      _connectionEpoch++;
      _connectTimeout?.cancel();
      _connectTimeout = Timer(Duration(seconds: activeServer?.protocol == 'wireguard' ? 50 : 100), () {
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
        if (activeServer?.protocol == 'vless' || activeServer?.protocol == 'shadowsocks') {
          connectionVerified = event.quality;
          state = ConnectionState.connected; message = event.message ?? 'Xray: ответ через сервер получен';
          _scheduleTraffic(); _notify();
        } else if (!_verifying && state != ConnectionState.connected) { unawaited(_verifyInternet()); }
      case ConnectionState.connecting:
        _nativeConnected = false;
        connectionStage = event.message ?? connectionStage;
        message = connectionStage; traffic.reset(); _trafficTimer?.cancel();
        _nativeNeedsStop = true;
        if (state == ConnectionState.connected || _verifying) {
          _connectionEpoch++;
        }
        state = ConnectionState.connecting;
        _connectTimeout ??= Timer(Duration(seconds: activeServer?.protocol == 'wireguard' ? 50 : 100), () { unawaited(_fail('Таймаут VPN')); });
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
        state = ConnectionState.disconnected;
        _notify();
      case ConnectionState.error:
        unawaited(_fail(event.message ?? 'Ошибка VPN'));
    }
  }

  Future<void> _verifyInternet() async {
    _verifying = true;
    final epoch = _connectionEpoch;
    try {
      final result = await const MethodChannel('quietvpn/xray-state')
        .invokeMapMethod<String, dynamic>('tunnelProbe').timeout(const Duration(seconds: 30));
      if ((result?['delay'] as num? ?? -1) < 0) throw const HttpException('System VPN check failed');
      if (!_disposed && epoch == _connectionEpoch && _nativeNeedsStop) {
        _connectTimeout?.cancel(); _connectTimeout = null; state = ConnectionState.connected;
        connectionVerified = result?['quality'] == true;
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
  Future<void> _fail(String reason) async {
    if (_stopping || _disposed) return;
    if (busy) { _pendingFailure = reason; return; }
    traffic.reset(); _trafficTimer?.cancel();
    _stopping = true; _nativeConnected = false; _connectionEpoch++; _connectTimeout?.cancel(); _connectTimeout = null;
    try {
      if (_nativeNeedsStop) await engine.disconnect();
      _nativeNeedsStop = false; activeServer = null;
      message = reason;
    } catch (_) { message = '$reason Отключение не подтверждено — повторите его.'; }
    finally { _stopping = false; state = ConnectionState.error; _notify(); }
  }
  Future<void> disconnect() async {
    if (busy || _stopping) return;
    traffic.reset(); _trafficTimer?.cancel();
    busy = true; _stopping = true; _nativeConnected = false; _connectionEpoch++;
    _connectTimeout?.cancel(); _connectTimeout = null; _notify();
    try {
      await engine.disconnect(); _nativeNeedsStop = false; activeServer = null;
      state = ConnectionState.disconnected; message = null;
    } catch (_) { state = ConnectionState.error; message = 'Отключение не подтверждено. Повторите или используйте настройки системы.'; }
    finally { busy = false; _stopping = false; _notify(); }
  }
  @override void dispose() {
    _disposed = true; _autoEpoch++; _autoMonitor.cancel(); _trafficTimer?.cancel(); _poll?.cancel(); _connectTimeout?.cancel();
    monitor.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
