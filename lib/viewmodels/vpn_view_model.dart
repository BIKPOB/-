import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../core/models.dart';
import '../core/profile_policy.dart';
import '../core/server_monitor.dart';
import '../data/catalog_repository.dart';
import '../data/profile_store.dart';
import '../platform/vpn_engine.dart';

class VpnViewModel extends ChangeNotifier {
  VpnViewModel(this.engine, this.catalog, this.store, this.monitor);
  final VpnEngine engine;
  final CatalogRepository catalog;
  final ProfileStore store;
  final ServerMonitor monitor;
  List<VpnServer> _public = [], _imports = [];
  List<VpnServer> get servers => [..._imports, ..._public];
  List<VpnServer> get filtered => servers.where((s) => (country == null || s.country == country) && (protocolFilter == null || s.protocol == protocolFilter)).toList();
  Map<String, HealthResult> health = {};
  ConnectionState state = ConnectionState.disconnected;
  String? selectedId, country, message, protocolFilter;
  VpnServer? activeServer;
  DateTime? catalogDate;
  int cacheBytes = 0;
  bool autoRefresh = true;
  bool cached = false, refreshing = false, busy = false, ready = false;
  bool _foreground = true, _disposed = false, _nativeNeedsStop = false, _stopping = false;
  bool _verifying = false;
  bool _nativeConnected = false;
  String? _pendingFailure;
  bool get canDisconnect => _nativeNeedsStop;
  int _connectionEpoch = 0, _probeEpoch = 0;
  Timer? _poll, _connectTimeout, _catalogTimer;
  StreamSubscription<EngineEvent>? _subscription;
  HttpClient? _verificationClient;
  VpnServer? get selected {
    for (final server in servers) { if (server.id == selectedId) return server; }
    return null;
  }
  void _notify() { if (!_disposed) notifyListeners(); }

  Future<void> initialize() async {
    _subscription = engine.events.listen(_onEvent);
    try {
      _imports = await store.load();
      await engine.initialize(); ready = true;
    } catch (_) { message = 'Не удалось инициализировать VPN или защищённое хранилище'; state = ConnectionState.error; }
    await refresh();
    _catalogTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (_foreground && autoRefresh) unawaited(refresh());
    });
    _notify();
  }
  Future<void> refresh({bool force = false}) async {
    if (refreshing || _disposed) return;
    refreshing = true; _notify();
    try {
      final result = await catalog.load(force: force);
      if (_disposed) return;
      _public = result.servers;
      cacheBytes = await catalog.cacheSize();
      autoRefresh = true;
      catalogDate = result.fetchedAt; cached = result.cached;
      if (selected == null && servers.isNotEmpty) selectedId = servers.first.id;
      message = '${result.servers.length} серверов; пропущено несовместимых профилей: ${result.rejected}'
        '${cached ? '. Используется кэш' : ''}';
      _scheduleProbe(immediate: true);
    } catch (error) { message = error is FormatException ? error.message : 'Не удалось загрузить базу. Проверьте сеть и повторите загрузку.'; }
    finally { refreshing = false; _notify(); }
  }
  Future<void> clearCatalogCache() async {
    if (refreshing || _disposed) return;
    refreshing = true; _notify();
    try {
      await catalog.clearCache();
      _probeEpoch++; monitor.cancel(); _poll?.cancel();
      _public = []; health = {}; cacheBytes = 0; cached = false; catalogDate = null;
      autoRefresh = false;
      if (selected == null) selectedId = _imports.isEmpty ? null : _imports.first.id;
      country = null;
      message = 'Кэш базы очищен. Нажмите «Скачать базу», чтобы загрузить её снова.';
    } catch (_) { message = 'Не удалось очистить кэш базы'; }
    finally { refreshing = false; _notify(); }
  }
  void select(String id) { selectedId = id; _notify(); }
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
    if (!_foreground || _disposed) return;
    _poll = Timer(Duration(milliseconds: immediate ? 0 : 30000 + Random().nextInt(3000)), () async {
      final epoch = _probeEpoch;
      final candidates = filtered.take(10).toList();
      final results = await monitor.sample(candidates);
      if (_disposed) return;
      if (epoch == _probeEpoch && _foreground) { health = {...health, ...results}; _notify(); }
      _scheduleProbe();
    });
  }
  Future<void> importProfile(String text, String name, String region) async {
    final parsed = ProfilePolicy.parse(text);
    final id = 'local-${sha256.convert(utf8.encode(parsed.text)).toString().substring(0, 24)}';
    final server = VpnServer(id: id, name: name, country: region.isEmpty ? 'Мои профили' : region,
      countryCode: '--', host: parsed.host, port: parsed.port, transport: parsed.transport,
      profile: parsed.text, source: 'Импорт', protocol: parsed.protocol);
    final updated = [..._imports.where((s) => s.id != id), server];
    await store.save(updated);
    _imports = updated; selectedId = id; country = null; protocolFilter = parsed.protocol;
    message = '${parsed.protocol} профиль импортирован'; _scheduleProbe(immediate: true); _notify();
  }
  Future<void> removeSelected() async {
    final server = selected;
    if (server == null || server.source != 'Импорт' || activeServer?.id == server.id) return;
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
      _connectionEpoch++;
      _connectTimeout?.cancel();
      _connectTimeout = Timer(const Duration(seconds: 50), () {
        if (state == ConnectionState.connecting) {
          unawaited(_fail('Таймаут подключения. Попробуйте другой сервер.'));
        }
      });
      _notify();
      await engine.connect(server, auth);
    } catch (error) {
      await _fail(error is StateError ? error.message.toString() : 'Не удалось запустить VPN');
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
        _nativeConnected = true;
        _nativeNeedsStop = true;
        if (!_verifying && state != ConnectionState.connected) unawaited(_verifyInternet());
      case ConnectionState.connecting:
        _nativeConnected = false;
        _nativeNeedsStop = true;
        if (state == ConnectionState.connected || _verifying) {
          _verificationClient?.close(force: true); _connectionEpoch++;
        }
        state = ConnectionState.connecting;
        _connectTimeout ??= Timer(const Duration(seconds: 50), () { unawaited(_fail('Таймаут OpenVPN')); });
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
        _verificationClient?.close(force: true);
        state = ConnectionState.disconnected;
        _notify();
      case ConnectionState.error:
        unawaited(_fail(event.message ?? 'Ошибка OpenVPN'));
    }
  }

  Future<void> _verifyInternet() async {
    _verifying = true;
    final epoch = _connectionEpoch;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _verificationClient = client;
    try {
      await (() async {
        final request = await client.getUrl(Uri.parse('https://www.gstatic.com/generate_204'));
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 204) throw const HttpException('Connectivity check failed');
        await response.drain<void>();
      })().timeout(const Duration(seconds: 8));
      if (!_disposed && epoch == _connectionEpoch && _nativeNeedsStop) {
        _connectTimeout?.cancel(); _connectTimeout = null; state = ConnectionState.connected;
        message = '${activeServer?.protocol ?? 'VPN'} подключён, HTTPS-проверка пройдена'; _notify();
      }
    } catch (_) {
      if (epoch == _connectionEpoch && !_stopping) await _fail('Туннель поднят, но HTTPS-проверка не прошла');
    } finally {
      client.close(force: true);
      if (identical(_verificationClient, client)) _verificationClient = null;
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
    _stopping = true; _nativeConnected = false; _connectionEpoch++; _connectTimeout?.cancel(); _connectTimeout = null;
    _verificationClient?.close(force: true);
    try {
      if (_nativeNeedsStop) await engine.disconnect();
      _nativeNeedsStop = false; activeServer = null;
      message = reason;
    } catch (_) { message = '$reason Отключение не подтверждено — повторите его.'; }
    finally { _stopping = false; state = ConnectionState.error; _notify(); }
  }
  Future<void> disconnect() async {
    if (busy || _stopping) return;
    busy = true; _stopping = true; _nativeConnected = false; _connectionEpoch++;
    _connectTimeout?.cancel(); _connectTimeout = null; _verificationClient?.close(force: true); _notify();
    try {
      await engine.disconnect(); _nativeNeedsStop = false; activeServer = null;
      state = ConnectionState.disconnected; message = null;
    } catch (_) { state = ConnectionState.error; message = 'Отключение не подтверждено. Повторите или используйте настройки системы.'; }
    finally { busy = false; _stopping = false; _notify(); }
  }
  @override void dispose() {
    _disposed = true; _poll?.cancel(); _catalogTimer?.cancel(); _connectTimeout?.cancel();
    _verificationClient?.close(force: true); monitor.cancel(); catalog.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
