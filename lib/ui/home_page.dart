import 'dart:async';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import '../platform/desktop_capabilities.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/traffic.dart';
import '../viewmodels/vpn_view_model.dart';
import 'catalog_page.dart';
import 'app_routing_page.dart';
import 'site_bypass_page.dart';
import '../core/site_bypass.dart';
import 'latency_indicator.dart';
import 'quiet_theme.dart';
import 'package:tray_manager/tray_manager.dart';

class HomePage extends StatefulWidget {
  const HomePage(this.vm, {super.key});
  final VpnViewModel vm;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, WindowListener, TrayListener {
  static const _widgetChannel = MethodChannel('quietvpn/widget');
  bool _settings = false,
      _deep = false,
      _initialized = false,
      _compact = false,
      _trayReady = false;
  final _session = Stopwatch();
  Timer? _clock;
  bool _closing = false;
  @override
  void onWindowClose() async {
    if (_trayReady) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  Future<void> _exit() async {
    if (_closing) return;
    _closing = true;
    try {
      await vm.cancelAutoSelection();
      while (vm.busy || vm.autoSelecting) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (vm.canDisconnect) await vm.disconnect();
      if (!vm.canDisconnect) await windowManager.destroy();
    } finally {
      _closing = false;
    }
  }

  VpnViewModel get vm => widget.vm;
  @override
  void initState() {
    super.initState();
    if (vm.engine is DesktopCapabilities) windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    vm.addListener(_observe);
    if (Platform.isAndroid) {
      _widgetChannel.setMethodCallHandler((call) async {
        if (call.method == 'actionAvailable') await _consumeWidgetAction();
      });
    }
    if (Platform.isWindows) trayManager.addListener(this);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _session.isRunning) setState(() {});
    });
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (vm.engine is DesktopCapabilities) return;
    // Notification shade and permission dialogs remove focus without hiding the app.
    // Ignore inactive, including the transition back from paused to resumed.
    switch (state) {
      case AppLifecycleState.resumed:
        vm.setForeground(true);
        if (Platform.isAndroid) unawaited(_consumeWidgetAction());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        vm.setForeground(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (vm.engine is DesktopCapabilities) windowManager.removeListener(this);
    _clock?.cancel();
    vm.removeListener(_observe);
    if (Platform.isAndroid) _widgetChannel.setMethodCallHandler(null);
    if (Platform.isWindows) trayManager.removeListener(this);
    vm.dispose();
    super.dispose();
  }

  void _add() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => CatalogPage(vm)),
  );
  Future<void> _diagnostics() async {
    final native = vm.engine is DesktopCapabilities
        ? await (vm.engine as DesktopCapabilities).diagnostics()
        : await const MethodChannel(
                'quietvpn/diagnostics',
              ).invokeMethod<String>('report') ??
              '';
    final report =
        '$native\nПротокол: ${vm.activeServer?.protocol ?? vm.selected?.protocol ?? '—'}\n'
        'Состояние: ${vm.state.name}\nЭтап: ${vm.connectionStage ?? '—'}\n${vm.message ?? ''}\n'
        'Интернет и качество подтверждены: ${vm.connectionVerified}\n'
        'Сеть: ${vm.networkContext.label} · обучающих замеров: ${vm.learningSamples}\n'
        '${vm.baselineStatus}\n${vm.networkAnalysisReport}\nФоновая связь: ${vm.reconnectAdvice ?? "предупреждений нет"}\n'
        'Резерв: ${vm.reserveStatus}\n'
        'ИИ: ${vm.autoStatus ?? 'не запускался'}\n${vm.autoAttemptReports.join('\n\n')}';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Диагностика'),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
            },
            child: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _learning() async {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Опыт нейросети: ${vm.learningSamples}'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Text(
              vm.learningJournal.isEmpty
                  ? 'Пока нет измерений. Модель начинает без готовых знаний о ваших серверах.'
                  : vm.learningJournal.reversed
                        .take(30)
                        .map(
                          (e) =>
                              '${e['time']} · ${e['network']} · ${e['protocol']}\n${switch (e['outcome']) {
                                'verified' => 'Проверено',
                                'proxy_verified' => 'HTTPS и скорость через прокси проверены',
                                'proxy_unconfirmed' => 'Прокси не подтвердил HTTPS',
                                'slow_or_unstable' => 'Медленно или повторный замер не прошёл',
                                'network_uncertain' => 'Сеть не определена',
                                _ => 'Соединение не подтверждено',
                              }} · ${e['bytesPerSecond'] == null ? 'скорость не измерена' : '${((e['bytesPerSecond'] as num) / 1024).round()} КиБ/с'}',
                        )
                        .join('\n\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: vm.autoSelecting
                ? null
                : () async {
                    final yes = await showDialog<bool>(
                      context: c,
                      builder: (d) => AlertDialog(
                        title: const Text('Сбросить обучение?'),
                        content: const Text(
                          'Будут удалены модель и история измерений. VPN-профили сохранятся.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Отмена'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const Text('Сбросить'),
                          ),
                        ],
                      ),
                    );
                    if (yes == true) {
                      await vm.resetLearning();
                      if (c.mounted) Navigator.pop(c);
                    }
                  },
            child: const Text('Сбросить обучение'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  String get _status => vm.autoSelecting
      ? 'ИИ-подбор'
      : switch (vm.state) {
          ConnectionState.connected =>
            vm.connectionVerified ? 'Подключено' : 'Проверка связи',
          ConnectionState.connecting => 'Подключение',
          ConnectionState.error => 'Ошибка подключения',
          _ => 'Отключено',
        };
  bool get _working =>
      vm.busy || vm.autoSelecting || vm.state == ConnectionState.connecting;
  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 420);
  String get _elapsed {
    final seconds = _session.elapsed.inSeconds;
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _observe() {
    if (vm.state == ConnectionState.connected && !vm.autoSelecting) {
      if (!_session.isRunning) _session.start();
    } else {
      _session.stop();
      _session.reset();
    }
    if (Platform.isAndroid) {
      unawaited(
        _widgetChannel
            .invokeMethod<void>('update', {
              'status': _status,
              'active': vm.state == ConnectionState.connected,
              'download': formatTrafficRate(vm.traffic.download),
              'upload': formatTrafficRate(vm.traffic.upload),
              'reserve': vm.reserveEnabled,
            })
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _initializeTray() async {
    if (Platform.isWindows && vm.engine is DesktopCapabilities) {
      try {
        await trayManager.setIcon('assets/design/app_icon.ico');
        await trayManager.setToolTip('Quiet VPN');
        await trayManager.setContextMenu(
          Menu(
            items: [
              MenuItem(key: 'open', label: 'Открыть Quiet VPN'),
              MenuItem(key: 'exit', label: 'Отключить VPN и выйти'),
            ],
          ),
        );
        _trayReady = true;
      } catch (_) {
        /* Keep normal window available if the shell rejects the tray icon. */
      }
    }
  }

  Future<void> _initialize() async {
    unawaited(_initializeTray());
    await vm.initialize();
    if (!mounted) return;
    setState(() => _initialized = true);
    if (Platform.isAndroid) await _consumeWidgetAction();
  }

  Future<void> _consumeWidgetAction() async {
    if (!_initialized || !mounted) return;
    String? action;
    try {
      action = await _widgetChannel.invokeMethod<String>('consumeAction');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (!mounted || action == null) return;
    switch (action) {
      case 'power':
        await _power();
      case 'search':
        await _servers();
      case 'ai':
        await _runAi();
      case 'reserve':
        setState(() => _settings = true);
    }
  }

  Future<void> _power() async {
    if (vm.autoSelecting) {
      await vm.cancelAutoSelection();
      return;
    }
    if (vm.busy || !vm.ready) return;
    if (vm.canDisconnect) {
      await vm.disconnect();
      return;
    }
    if (vm.selected == null) {
      await _panel(
        'Выберите сервер',
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Выберите сервер для подключения или начните ИИ поиск',
            style: TextStyle(fontSize: 30),
          ),
        ),
        color: quietRed,
      );
      return;
    }
    await vm.connect(null);
  }

  Future<void> _runAi() async {
    if (vm.autoSelecting) {
      await vm.cancelAutoSelection();
      return;
    }
    if (!vm.ready || vm.busy) return;
    if (vm.canDisconnect) {
      await vm.checkReserve();
      return;
    }
    if (_deep) await vm.enableNetworkAnalysis();
    if (!mounted) return;
    await vm.autoConnect(deep: _deep);
  }

  Future<void> _panel(
    String title,
    Widget content, {
    Color color = quietNavy,
  }) async {
    if (_compact) await _showFull();
    if (!mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: Colors.black38,
      transitionDuration: _motion,
      pageBuilder: (c, animation, secondary) => SafeArea(
        child: Center(
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 660,
              maxHeight: MediaQuery.sizeOf(c).height * .9,
            ),
            height: color == quietRed ? null : MediaQuery.sizeOf(c).height * .9,
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(title, style: quietText(24))),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(c),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white),
                  Flexible(child: content),
                ],
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (c, animation, secondary, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, .08),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _servers() => _panel(
    'Выбор сервера',
    ListenableBuilder(
      listenable: vm,
      builder: (c, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Все'),
                selected: vm.protocolFilter == null,
                onSelected: (_) => vm.filterProtocol(null),
              ),
              for (final p in protocols.entries)
                ChoiceChip(
                  label: Text(p.value),
                  selected: vm.protocolFilter == p.key,
                  onSelected: (_) => vm.filterProtocol(p.key),
                ),
              IconButton(
                tooltip: 'Проверить адреса',
                onPressed: vm.refreshLatency,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (vm.filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Нет сохранённых серверов. Добавьте профиль или запустите ИИ-подбор.',
                    ),
                  ),
                for (final server in vm.filtered)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: ListTile(
                      selected: vm.selectedId == server.id,
                      selectedColor: quietNavy,
                      onTap: _working
                          ? null
                          : () {
                              vm.select(server.id);
                              Navigator.pop(c);
                            },
                      title: Text(server.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${protocols[server.protocol]} · ${server.country}',
                          ),
                          LatencyIndicator(vm.health[server.id]),
                        ],
                      ),
                      trailing: IconButton(
                        tooltip: 'Удалить профиль',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _working || vm.activeServer?.id == server.id
                            ? null
                            : () async {
                                final yes = await showDialog<bool>(
                                  context: c,
                                  builder: (d) => AlertDialog(
                                    title: const Text('Удалить сервер?'),
                                    content: Text(server.name),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(d, false),
                                        child: const Text('Отмена'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(d, true),
                                        child: const Text('Удалить'),
                                      ),
                                    ],
                                  ),
                                );
                                if (yes == true) {
                                  vm.select(server.id);
                                  await vm.removeSelected();
                                }
                              },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: _working
                ? null
                : () {
                    Navigator.pop(c);
                    _add();
                  },
            icon: const Icon(Icons.add),
            label: const Text('Добавить сервер'),
          ),
        ],
      ),
    ),
    color: quietGreen,
  );
  Future<void> _information() => _panel(
    'Информация',
    ListenableBuilder(
      listenable: vm,
      builder: (c, _) => ListView(
        shrinkWrap: true,
        children: [
          Text(_status, style: quietText(26)),
          Text(
            vm.activeServer?.name ?? vm.selected?.name ?? 'Сервер не выбран',
          ),
          Text(
            'Интернет и качество подтверждены: ${vm.connectionVerified ? 'да' : 'нет'}',
          ),
          if (vm.connectionStage != null) Text(vm.connectionStage!),
          if (vm.message != null) Text(vm.message!),
          const SizedBox(height: 16),
          Text(vm.networkContext.label),
          Text(vm.analysisStatus),
          Text(vm.baselineStatus),
          if (vm.backgroundStatus != null) Text(vm.backgroundStatus!),
          if (vm.autoStatus != null) Text(vm.autoStatus!),
          if (vm.autoPlan.isNotEmpty) Text(vm.autoPlan),
          Text('Резерв: ${vm.reserveStatus}'),
          const Text(
            'Резерв VLESS/Shadowsocks проверяется автоматически. На Android восстановление работает, пока приложение открыто; на Windows — также в трее. Смена сервера может вызвать паузу.',
          ),
          if (vm.reconnectAdvice != null) ...[
            Text(vm.reconnectAdvice!),
            TextButton(
              onPressed: _working ? null : () => vm.reconnectFromAdvice(),
              child: const Text('Переподключиться'),
            ),
            TextButton(
              onPressed: _working
                  ? null
                  : () => vm.reconnectFromAdvice(findAnother: true),
              child: const Text('Найти другой сервер'),
            ),
          ],
          const Divider(),
          const Text(
            'Быстрый подбор: до 15 секунд на поиск; остановка движка может занять дополнительное время. Глубокий: до 8 VPN-профилей за раунд, до 4 раундов и 12 минут. Во время подбора оставьте приложение открытым.',
          ),
          const Text(
            'Скорость до тестового узла не гарантирует доступность всех сайтов. Цель учитывает свежий замер сети; без него — 5 Мбит/с. Медленный VPN не сохраняется как результат автоподбора.',
          ),
          const Text(
            'Фоновый анализ без VPN: до 8 МиБ/сутки в лимитной сети, до 32 МиБ в безлимитной. Проверки качества VPN: до 3 МиБ/час. Резерв: до 24/96 МиБ/час соответственно, плюс служебный трафик.',
          ),
          TextButton(
            onPressed: _diagnostics,
            child: const Text('Диагностика и копирование отчёта'),
          ),
          if (Platform.isWindows)
            TextButton(
              onPressed: _exit,
              child: const Text('Отключить VPN и выйти'),
            ),
        ],
      ),
    ),
  );
  Widget _aiSettings() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: quietGreen, width: 2),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      children: [
        Row(
          children: [
            const Expanded(child: Text('ИИ резерв')),
            Switch(
              value: vm.reserveEnabled,
              onChanged: _working ? null : vm.setReserveEnabled,
            ),
            IconButton(
              tooltip: 'Закрыть настройки ИИ',
              onPressed: () => setState(() => _settings = false),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: _learning,
          icon: const Icon(Icons.psychology_outlined),
          label: const Text('Обучение ИИ'),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Быстрый')),
              ButtonSegment(value: true, label: Text('Глубокий')),
            ],
            selected: {_deep},
            onSelectionChanged: _working
                ? null
                : (value) => setState(() => _deep = value.first),
          ),
        ),
      ],
    ),
  );
  Widget _controls() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 1,
        child: QuietAction(
          label: vm.autoSelecting
              ? 'Остановить подбор'
              : vm.canDisconnect
              ? 'Отключить VPN'
              : 'Подключить VPN',
          onTap: !vm.ready || vm.busy && !vm.autoSelecting ? null : _power,
          child: AnimatedSwitcher(
            duration: _motion,
            child: _working
                ? const AspectRatio(
                    key: ValueKey('working'),
                    aspectRatio: 1,
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  )
                : AspectRatio(
                    key: ValueKey(vm.canDisconnect),
                    aspectRatio: 1,
                    child: quietAsset(
                      vm.canDisconnect ? 'power_on' : 'power_off',
                      108,
                    ),
                  ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 2,
        child: Column(
          children: [
            AnimatedSize(
              duration: _motion,
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: _settings
                  ? _aiSettings()
                  : Row(
                      children: [
                        Expanded(
                          child: QuietAction(
                            label: vm.autoSelecting
                                ? 'Остановить подбор'
                                : vm.canDisconnect
                                ? 'Проверить резерв'
                                : 'ИИ-поиск',
                            color: quietGreen,
                            radius: const BorderRadius.horizontal(left: Radius.circular(100)),
                            onTap: !vm.ready || vm.busy && !vm.autoSelecting
                                ? null
                                : _runAi,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  quietAsset(
                                    vm.canDisconnect ? 'reserve' : 'ai',
                                    30,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        vm.autoSelecting
                                            ? 'Стоп'
                                            : vm.canDisconnect
                                            ? 'ИИ резерв'
                                            : 'ИИ поиск',
                                        style: quietText(25),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        QuietAction(
                          label: 'Настройки ИИ-поиска',
                          onTap: () => setState(() => _settings = true),
                          child: quietAsset('settings', 54),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: _motion,
              child: _working
                  ? SizedBox(
                      key: const ValueKey('progress'),
                      height: 48,
                      child: Row(
                        children: [
                          quietAsset('search', 36),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: LinearProgressIndicator(
                              color: quietGreen,
                              minHeight: 12,
                              borderRadius: BorderRadius.all(
                                Radius.circular(12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : QuietAction(
                      key: const ValueKey('servers'),
                      label: 'Выбор сервера',
                      color: quietGreen,
                      onTap: _servers,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            quietAsset('search', 30),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Выбор сервера',
                                  style: quietText(25),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ],
  );
  Future<void> _openBypass() async {
    if (!vm.ready || _working) return;
    final Widget page;
    if (vm.engine is SiteBypassHost) {
      page = SiteBypassPage(host: vm.engine as SiteBypassHost, vpnActive: vm.canDisconnect);
    } else if (Platform.isAndroid) {
      page = AppRoutingPage(vpnActive: vm.canDisconnect);
    } else {
      return;
    }
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _bypassButton() {
    final label = Platform.isWindows ? 'Обход сайтов' : 'Обход приложений';
    return QuietAction(label: label, color: quietGreen,
      onTap: vm.ready && !_working && (Platform.isAndroid || vm.engine is SiteBypassHost) ? _openBypass : null,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.alt_route, color: Colors.white, size: 26),
          const SizedBox(width: 10), Flexible(child: Text(label, style: quietText(24))),
        ])));
  }

  Widget _mainScreen() => LayoutBuilder(
    builder: (context, bounds) {
      final height = bounds.maxHeight.clamp(780.0, 900.0);
      return SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: SizedBox(
              height: height + (_settings ? 120 : 0) + (vm.reconnectAdvice != null ? 48 : 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Spacer(),
                        quietAsset('logo', 42),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              tooltip: 'Диагностика',
                              onPressed: _diagnostics,
                              icon: quietAsset('bug', 24),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: height * .307 - 62),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: quietGreen),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              children: [
                                const Text('Использование данных'),
                                const SizedBox(width: 18),
                                quietAsset('download', 24),
                                Text(formatTrafficRate(vm.traffic.download)),
                                quietAsset('upload', 24),
                                Text(formatTrafficRate(vm.traffic.upload)),
                              ],
                            ),
                          ),
                          const Divider(color: Colors.white, height: 24),
                          Row(
                            children: [
                              quietAsset('timer', 36),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Время\nиспользования',
                                    style: quietText(26),
                                  ),
                                ),
                              ),
                              Text(
                                _elapsed,
                                style: quietText(
                                  24,
                                  color: quietGreen,
                                  bold: true,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: height * .10),
                    _controls(),
                    const SizedBox(height: 12),
                    _bypassButton(),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _information,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: quietNavy, width: 2),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [quietAsset('info', 14), const SizedBox(width: 6), const Text('Информация')]),
                    ),
                    if (vm.reconnectAdvice != null)
                      TextButton(
                        onPressed: _information,
                        child: const Text(
                          'Связь нестабильна — переподключение',
                        ),
                      ),
                    if (vm.autoStatus != null && !_working)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: GestureDetector(
                          onTap: _information,
                          child: Text(
                            vm.autoStatus!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    Spacer(flex: 2),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _compactScreen() => Padding(
    padding: const EdgeInsets.all(18),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              quietAsset('logo', 38),
              const Spacer(),
              Text(_status, style: quietText(30)),
              const SizedBox(height: 12),
              Text(
                '↓ ${formatTrafficRate(vm.traffic.download)}   ↑ ${formatTrafficRate(vm.traffic.upload)}',
              ),
              const Spacer(),
              TextButton(
                onPressed: _showFull,
                child: const Text('Открыть приложение'),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 150,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Expanded(
                    child: QuietAction(
                      label: 'Подключение',
                      onTap: _power,
                      child: quietAsset(
                        vm.canDisconnect ? 'power_on' : 'power_off',
                        64,
                      ),
                    ),
                  ),
                  Expanded(
                    child: QuietAction(
                      label: 'Серверы',
                      onTap: _servers,
                      child: quietAsset('search', 44),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: QuietAction(
                      label: 'ИИ-поиск',
                      onTap: _runAi,
                      child: quietAsset('ai', 44),
                    ),
                  ),
                  Expanded(
                    child: QuietAction(
                      label: 'Резерв и настройки',
                      onTap: () async {
                        await _showFull();
                        if (mounted) setState(() => _settings = true);
                      },
                      child: quietAsset('reserve', 44),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Future<void> _showFull() async {
    setState(() => _compact = false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSize(const Size(480, 850));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() async {
    if (!mounted) return;
    if (_compact && await windowManager.isVisible()) {
      await windowManager.hide();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _compact = true);
    await windowManager.setSize(const Size(480, 280));
    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'open') unawaited(_showFull());
    if (item.key == 'exit') unawaited(_exit());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm,
    builder: (context, _) => Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: quietGradient),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: _motion,
            child: !_initialized
                ? Center(
                    key: const ValueKey('loading'),
                    child: FractionallySizedBox(
                      widthFactor: .75,
                      child: quietAsset('loading', 220),
                    ),
                  )
                : _compact
                ? _compactScreen()
                : _mainScreen(),
          ),
        ),
      ),
    ),
  );
}
