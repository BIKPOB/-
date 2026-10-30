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
import 'chat_motion.dart';
import 'package:tray_manager/tray_manager.dart';

class HomePage extends StatefulWidget {
  const HomePage(this.vm, {super.key});
  final VpnViewModel vm;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, WindowListener, TrayListener {
  bool _settings = false,
      _deep = false,
      _initialized = false,
      _trayReady = false;
  final _chatScroll = ScrollController();
  int _seenMessages = 0;
  bool _seenLive = false;
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
    if (Platform.isWindows) trayManager.addListener(this);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (vm.sessionClock.startedAt != null || vm.autoSelecting)) {
        setState(() {});
      }
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
    _chatScroll.dispose();
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
    await _panel(
      'Диагностика',
      Column(
        children: [
          Expanded(child: SingleChildScrollView(child: SelectableText(report))),
          OutlinedButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            icon: const Icon(Icons.copy),
            label: const Text('Копировать отчёт'),
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
    final seconds = vm.sessionClock.elapsed.inSeconds;
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _observe() {
    final last = vm.messages.isEmpty ? 0 : vm.messages.last.id;
    final live =
        vm.canDisconnect &&
        !vm.autoSelecting &&
        vm.sessionClock.startedAt != null;
    if (_seenMessages == last && live == _seenLive) return;
    _seenMessages = last;
    _seenLive = live;
    final follow =
        !_chatScroll.hasClients || _chatScroll.position.extentAfter < 120;
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_chatScroll.hasClients) return;
        unawaited(
          _chatScroll.animateTo(
            _chatScroll.position.maxScrollExtent,
            duration: _motion,
            curve: Curves.easeOutCubic,
          ),
        );
      });
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
      vm.postMessage(
        'Выберите сервер для подключения или начните ИИ поиск',
        error: true,
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
    if (!mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: Colors.black38,
      transitionDuration: _motion,
      pageBuilder: (c, animation, secondary) => SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 660,
              maxHeight: MediaQuery.sizeOf(c).height * .9,
            ),
            height: color == quietRed ? null : MediaQuery.sizeOf(c).height * .9,
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewPaddingOf(c).bottom),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
              begin: const Offset(0, 1),
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
          Text('Время подключения: $_elapsed'),
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
            'Скорость до тестового узла не гарантирует доступность всех сайтов. Цель учитывает свежий замер сети, но не превышает 1 МБ/с (8 Мбит/с); без замера — 5 Мбит/с. Медленный VPN не сохраняется как результат автоподбора.',
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
    key: const ValueKey('ai-settings'),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: quietGreen,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Switch(
              value: vm.reserveEnabled,
              activeColor: quietNavy,
              onChanged: _working ? null : vm.setReserveEnabled,
            ),
            const Expanded(child: Text('Поиск резерва')),
            IconButton(
              tooltip: 'Закрыть настройки ИИ',
              onPressed: () => setState(() => _settings = false),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white, width: 2),
                ),
                onPressed: _working
                    ? null
                    : () => setState(() => _deep = !_deep),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _deep ? 'Глубокий поиск' : 'Быстрый поиск',
                    key: ValueKey(_deep),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Обучение ИИ',
              onPressed: _learning,
              icon: quietAsset('learning', 30),
            ),
          ],
        ),
      ],
    ),
  );

  // Page 2, 48:1343. Coordinates are the Figma geometry divided by ten.
  // The decorative frame continues below the viewport; controls stay above
  // the system navigation inset. Do not scale each icon independently.
  Widget _dock() => LayoutBuilder(builder: (context, bounds) {
    final scale = bounds.maxWidth / 376.8;
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    final height = (_settings ? 174.0 : 129.8) * scale + inset;
    return AnimatedSize(
      duration: _motion,
      alignment: Alignment.bottomCenter,
      curve: Curves.easeInOutCubic,
      child: SizedBox(
      key: const ValueKey('main-dock'),
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 10.5 * scale, right: 10.5 * scale, top: 0,
            bottom: -200 * scale,
            child: DecoratedBox(
              key: const ValueKey('dock-frame'),
              decoration: BoxDecoration(
                border: Border.all(color: quietGreen, width: 2 * scale),
                borderRadius: BorderRadius.circular(23.885 * scale),
              ),
            ),
          ),
          Positioned(
            left: 0, right: 0, top: 0,
            height: (_settings ? 174.0 : 129.8) * scale,
            child: FittedBox(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 376.8, height: _settings ? 174 : 129.8,
                child: Stack(children: [
                  if (_settings)
                    Positioned(left: 26.75, top: 18.8, width: 259.2,
                      child: _aiSettings())
                  else ...[
                    Positioned(left: 26.75, top: 18.787,
                      width: 230.919, height: 22.958,
                      child: QuietAction(
                        label: vm.autoSelecting ? 'Остановить подбор' :
                          vm.canDisconnect ? 'Проверить резерв' : 'ИИ-поиск',
                        color: quietGreen,
                        radius: const BorderRadius.horizontal(left: Radius.circular(23.8)),
                        onTap: !vm.ready || vm.busy && !vm.autoSelecting ? null : _runAi,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6.6),
                          child: Row(children: [
                            quietAsset(vm.canDisconnect && !vm.autoSelecting ? 'reserve' : 'ai', 16.976),
                            const SizedBox(width: 3.7),
                            Expanded(child: Text(vm.autoSelecting ? 'ИИ поиск…' :
                              vm.canDisconnect ? 'Подобрать резерв' : 'ИИ поиск',
                              style: quietText(12.8), maxLines: 1)),
                          ]),
                        ),
                      ),
                    ),
                    Positioned(left: 257.669, top: 18.787,
                      width: 28.281, height: 22.958,
                      child: QuietAction(
                        key: const ValueKey('ai-settings-button'),
                        label: 'Настройки ИИ-поиска',
                        radius: const BorderRadius.horizontal(right: Radius.circular(23.8)),
                        onTap: () => setState(() => _settings = true),
                        child: quietAsset('settings', 28.281),
                      ),
                    ),
                    Positioned(left: 26.663, top: 50.473, width: 103.963, height: 26.814,
                      child: _navButton('Информация', 'info', _information, color: quietNavy)),
                    Positioned(left: 142.984, top: 50.473, width: 68.866, height: 26.814,
                      child: _navButton('Сервера', 'search', _servers, tooltip: 'Выбор сервера')),
                    Positioned(left: 224.209, top: 50.473, width: 61.654, height: 26.814,
                      child: _navButton('Обход', 'bypass',
                        vm.ready && !_working && (Platform.isAndroid || vm.engine is SiteBypassHost)
                          ? _openBypass : null,
                        tooltip: Platform.isWindows ? 'Обход сайтов' : 'Обход приложений')),
                    if (vm.autoSelecting && vm.searching)
                      Positioned(left: 26.75, top: 88, width: 259.2,
                        child: vm.searchProgress.divisions == 0
                          ? const LinearProgressIndicator(color: Colors.white, backgroundColor: quietGreen)
                          : DividedProgress(divisions: vm.searchProgress.divisions,
                              completed: vm.searchProgress.steps(DateTime.now()))),
                  ],
                  Positioned(left: 296.979, top: 18.606, width: 56.556, height: 56.556,
                    child: QuietAction(
                      key: const ValueKey('power-button'),
                      label: vm.autoSelecting ? 'Остановить подбор' :
                        vm.canDisconnect ? 'Отключить VPN' : 'Подключить VPN',
                      onTap: !vm.ready || vm.busy && !vm.autoSelecting ? null : _power,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        switchInCurve: Curves.easeIn,
                        child: _working
                          ? const SizedBox(key: ValueKey('connecting'), width: 56.556,
                              height: 56.556, child: ConnectingControl())
                          : SizedBox(key: ValueKey(vm.canDisconnect), width: 56.556, height: 56.556,
                              child: quietAsset(vm.canDisconnect ? 'power_on' : 'power_off', 56.556)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  });

  Widget _navButton(String label, String asset, VoidCallback? action, {
    String? tooltip, Color color = quietGreen,
  }) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 2),
      borderRadius: BorderRadius.circular(23.885),
    ),
    child: QuietAction(
      label: tooltip ?? label, onTap: action,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: asset == 'info' ? 2 : asset == 'bypass' ? 6.1 : 14.4,
            child: quietAsset(asset, 14.4)),
          SizedBox(width: asset == 'info' ? 7.4 : 2),
          Text(label, maxLines: 1, style: quietText(12.8, color: color)),
          ]),
        ),
      ),
    ),
  );

  Future<void> _openBypass() async {
    if (!vm.ready || _working) return;
    final Widget page;
    if (vm.engine is SiteBypassHost) {
      page = SiteBypassPage(
        host: vm.engine as SiteBypassHost,
        vpnActive: vm.canDisconnect,
      );
    } else if (Platform.isAndroid) {
      page = AppRoutingPage(vpnActive: vm.canDisconnect);
    } else {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  Widget _mainScreen() => LayoutBuilder(
    builder: (context, bounds) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          children: [
            SizedBox(height: (bounds.maxHeight * .085).clamp(20, 80)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  const Expanded(child: SizedBox()),
                  quietAsset('logo', 48),
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
            ),
            Expanded(
              child: ListView(
                controller: _chatScroll,
                padding: EdgeInsets.fromLTRB(
                  24,
                  (bounds.maxHeight * .12).clamp(20, 110),
                  12,
                  16,
                ),
                children: [
                  for (final entry in vm.messages)
                    ChatBubble(
                      key: ValueKey(entry.id),
                      text: entry.text,
                      error: entry.error,
                    ),
                  if (vm.autoSelecting)
                    ChatBubble(
                      key: const ValueKey('search-progress'),
                      text: vm.searching
                          ? 'Подключение · ${vm.searchProgress.label(DateTime.now())}'
                          : vm.reserveStatus,
                    ),
                  if (vm.canDisconnect &&
                      !vm.autoSelecting &&
                      vm.sessionClock.startedAt != null)
                    ChatBubble(
                      key: const ValueKey('live-connection'),
                      text:
                          '${vm.state == ConnectionState.connected ? 'Подключено' : 'Проверка связи'} · $_elapsed\n'
                          'Скорость: ↓ ${formatTrafficRate(vm.traffic.download)}  ↑ ${formatTrafficRate(vm.traffic.upload)}',
                    ),
                  if (vm.reconnectAdvice != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton(
                        onPressed: _working
                            ? null
                            : () => vm.reconnectFromAdvice(),
                        child: const Text('Переподключиться'),
                      ),
                    ),
                ],
              ),
            ),
            _dock(),
          ],
        ),
      ),
    ),
  );
  Future<void> _showFull() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showFull());
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
          bottom: false,
          child: AnimatedSwitcher(
            duration: _motion,
            child: !_initialized
                ? Center(
                    key: const ValueKey('loading'),
                    child: FractionallySizedBox(
                      widthFactor: .75,
                      child: const LoadingMark(),
                    ),
                  )
                : _mainScreen(),
          ),
        ),
      ),
    ),
  );
}
