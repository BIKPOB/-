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
import 'latency_indicator.dart';

class HomePage extends StatefulWidget {
  const HomePage(this.vm, {super.key});
  final VpnViewModel vm;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> with WidgetsBindingObserver, WindowListener {
  bool _closing = false;
  @override void onWindowClose() async { await windowManager.minimize(); }
  Future<void> _exit() async {
    if (_closing) return;
    _closing = true;
    try {
      await vm.cancelAutoSelection();
      while (vm.busy || vm.autoSelecting) { await Future<void>.delayed(const Duration(milliseconds: 200)); }
      if (vm.canDisconnect) await vm.disconnect();
      if (!vm.canDisconnect) await windowManager.destroy();
    } finally { _closing = false; }
  }
  VpnViewModel get vm => widget.vm;
  @override void initState() { super.initState(); if (vm.engine is DesktopCapabilities) windowManager.addListener(this); WidgetsBinding.instance.addObserver(this); unawaited(vm.initialize()); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
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
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); if (vm.engine is DesktopCapabilities) windowManager.removeListener(this); vm.dispose(); super.dispose(); }
  void _add() => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CatalogPage(vm)));
  Future<void> _diagnostics() async {
    final native = vm.engine is DesktopCapabilities ? await (vm.engine as DesktopCapabilities).diagnostics()
      : await const MethodChannel('quietvpn/diagnostics').invokeMethod<String>('report') ?? '';
    final report = '$native\nПротокол: ${vm.activeServer?.protocol ?? vm.selected?.protocol ?? '—'}\n'
      'Состояние: ${vm.state.name}\nЭтап: ${vm.connectionStage ?? '—'}\n${vm.message ?? ''}\n'
      'Интернет и качество подтверждены: ${vm.connectionVerified}\n'
      'Сеть: ${vm.networkContext.label} · обучающих замеров: ${vm.learningSamples}\n'
      '${vm.baselineStatus}\n${vm.networkAnalysisReport}\n'
      'Резерв: ${vm.reserveStatus}\n'
      'ИИ: ${vm.autoStatus ?? 'не запускался'}\n${vm.autoAttemptReports.join('\n\n')}';
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('Диагностика'),
      content: SingleChildScrollView(child: SelectableText(report)), actions: [
        TextButton(onPressed: () async { await Clipboard.setData(ClipboardData(text: report)); }, child: const Text('Копировать')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]));
  }
  Future<void> _deepSearch() async {
    final deep = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Режим ИИ-подбора'),
      content: const Text('Состояние текущей сети анализируется автоматически. Перед подбором обновляются устаревшие измерения DNS, HTTPS и скорости без VPN. До трёх серверов одновременно проверяются через локальные прокси; затем скорость измеряется последовательно. Системный VPN включается для лучшего измеренного кандидата и проверяется повторно.\n\nБыстрый режим: до 12 кандидатов, бюджет прокси-проверки 45 с. Глубокий: до 24 прокси за 100 с, затем до 8 разных VPN-профилей за 640 с. Загрузка для сравнения прокси — до 9/18 МиБ в лимитной сети или 36/72 МиБ в безлимитной; финальная проверка VPN расходует дополнительный трафик. Это короткие замеры, а не гарантия скорости видео. Измерения хранятся локально и разделяются по подключению.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Глубокое сравнение')),
        FilledButton(onPressed: () => Navigator.pop(c, false), child: const Text('Быстро подключиться'))]));
    if (deep == null || !mounted) return;
    await vm.enableNetworkAnalysis();
    if (!mounted) return;
    await vm.autoConnect(deep: deep);
  }
  Future<void> _learning() async {
    await showDialog<void>(context: context, builder: (c) => AlertDialog(
      title: Text('Опыт нейросети: ${vm.learningSamples}'),
      content: SizedBox(width: 500, child: SingleChildScrollView(child: Text(
        vm.learningJournal.isEmpty ? 'Пока нет измерений. Модель начинает без готовых знаний о ваших серверах.' :
        vm.learningJournal.reversed.take(30).map((e) =>
          '${e['time']} · ${e['network']} · ${e['protocol']}\n${switch (e['outcome']) { 'verified' => 'Проверено', 'proxy_verified' => 'HTTPS и скорость через прокси проверены', 'proxy_unconfirmed' => 'Прокси не подтвердил HTTPS', 'slow_or_unstable' => 'Медленно или повторный замер не прошёл', 'network_uncertain' => 'Сеть не определена', _ => 'Соединение не подтверждено' }} · ${e['bytesPerSecond'] == null ? 'скорость не измерена' : '${((e['bytesPerSecond'] as num) / 1024).round()} КиБ/с'}').join('\n\n')))),
      actions: [TextButton(onPressed: vm.autoSelecting ? null : () async {
        final yes = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
          title: const Text('Сбросить обучение?'), content: const Text('Будут удалены модель и история измерений. VPN-профили сохранятся.'),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Сбросить'))]));
        if (yes == true) { await vm.resetLearning(); if (c.mounted) Navigator.pop(c); }
      }, child: const Text('Сбросить обучение')),
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Закрыть'))]));
  }
  @override Widget build(BuildContext context) => ListenableBuilder(listenable: vm, builder: (context, _) {
    final items = vm.filtered;
    return Scaffold(appBar: AppBar(title: const Text('Quiet VPN'), actions: [
      if (Platform.isWindows) IconButton(tooltip: 'Выйти и отключить VPN', onPressed: _exit, icon: const Icon(Icons.exit_to_app)),
      IconButton(tooltip: 'Проверить доступность адресов', onPressed: vm.refreshLatency, icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'Обучение', onPressed: _learning, icon: const Icon(Icons.psychology_outlined)),
      IconButton(tooltip: 'Диагностика', onPressed: _diagnostics, icon: const Icon(Icons.bug_report_outlined)),
    ]), floatingActionButton: FloatingActionButton.extended(onPressed: vm.autoSelecting || vm.busy ? null : _add, icon: const Icon(Icons.add), label: const Text('Добавить сервер')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: ListView(padding: const EdgeInsets.fromLTRB(16,16,16,100), children: [
      Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(switch(vm.state) { ConnectionState.connected => vm.connectionVerified ? 'Подключено · проверено' : 'Туннель включён · есть ограничения', ConnectionState.connecting => 'Подключение…',
          ConnectionState.error => 'Не удалось подключиться', _ => 'VPN выключен' }, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8), Text(vm.autoSelecting ? 'Сервер выбирается автоматически из публичных баз' : vm.activeServer?.name ?? vm.selected?.name ?? 'Запустите ИИ-подбор или добавьте свой сервер'),
        Text('↓ ${formatTrafficRate(vm.traffic.download)}   ↑ ${formatTrafficRate(vm.traffic.upload)}'),
        if (vm.message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(vm.message!)),
        FilledButton.icon(onPressed: vm.autoSelecting || vm.busy || !vm.ready || (!vm.canDisconnect && vm.selected == null) ? null : () async {
          if (vm.canDisconnect) { await vm.disconnect(); } else { await vm.connect(null); }
        }, icon: Icon(vm.canDisconnect ? Icons.stop : Icons.power_settings_new), label: Text(vm.canDisconnect ? 'Отключить' : 'Подключить')),
        OutlinedButton.icon(onPressed: !vm.ready || vm.busy && !vm.autoSelecting || vm.canDisconnect && !vm.autoSelecting ? null
          : () async { if (vm.autoSelecting) { await vm.cancelAutoSelection(); } else { await _deepSearch(); } },
          icon: Icon(vm.autoSelecting ? Icons.stop : Icons.auto_awesome),
          label: Text(vm.autoSelecting ? 'Остановить подбор' : 'ИИ-подбор')),
        if (!Platform.isWindows) OutlinedButton.icon(onPressed: vm.autoSelecting || vm.busy ? null : () =>
          Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AppRoutingPage(vpnActive: vm.canDisconnect))),
          icon: const Icon(Icons.call_split), label: const Text('Приложения в обход VPN')),
        const Text('Быстрый режим ищет VPN с целевой скоростью. Глубокий сравнивает несколько вариантов. На Windows цель — не ниже 5 Мбит/с, медленный VPN отмечается как резерв. Недавние результаты учитываются для похожих параметров сети. Во время подбора оставьте приложение открытым.'),
        if (Platform.isWindows) const Text('Проверка скорости VPN: до 4 МиБ на замер; глубокий режим делает до трёх замеров на кандидат. Скорость до тестового узла не гарантирует доступность YouTube.'),
        if (vm.reconnectAdvice != null) ...[
          Text(vm.reconnectAdvice!),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: vm.busy || vm.autoSelecting ? null : () => vm.reconnectFromAdvice(),
              child: const Text('Переподключиться')),
            TextButton(onPressed: vm.busy || vm.autoSelecting ? null : () => vm.reconnectFromAdvice(findAnother:true),
              child: const Text('Найти другой сервер')),
          ]),
        ],
        const Text('Во время VPN Android проверяет связь в фоне. При повторных сбоях появится предложение переподключиться. Проверки скорости: до 3 МиБ/час плюс служебный трафик.'),
        Text(vm.canDisconnect ? 'Автоанализ прямой сети приостановлен на время VPN' : vm.analysisStatus),
        Text('${vm.baselineStatus}${vm.canDisconnect ? ' · прямые замеры приостановлены' : ''}'),
        const Text('Автозамеры сети без VPN: до 8 МиБ/сутки в лимитной сети, до 32 МиБ в безлимитной, плюс служебный трафик. При VPN замеры приостановлены.'),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Проверенный резерв (экспериментально)'),
          subtitle: const Text('Для VLESS/Shadowsocks. До 24 МиБ/час в лимитной сети, 96 МиБ/час в безлимитной плюс служебный трафик. Возможна пауза при смене сервера. Android: пока приложение открыто.'),
          value: vm.reserveEnabled, onChanged: vm.busy || vm.autoSelecting ? null : vm.setReserveEnabled),
        if (vm.reserveEnabled) Text(vm.reserveStatus),
        if (vm.backgroundStatus != null && !vm.autoSelecting) Text(vm.backgroundStatus!),
        if (vm.autoStatus != null) Text(vm.networkContext.label),
        if (vm.autoStatus != null) Text(vm.autoStatus!),
        if (vm.autoPlan.isNotEmpty) Text(vm.autoPlan),
        if (vm.autoSelecting || vm.busy || vm.state == ConnectionState.connecting) const LinearProgressIndicator(),
      ]))),
      const SizedBox(height: 16), Text('Мои серверы', style: Theme.of(context).textTheme.titleLarge),
      Wrap(spacing: 6, children: [ChoiceChip(label: const Text('Все'), selected: vm.protocolFilter == null, onSelected: (_) => vm.filterProtocol(null)),
        for (final p in protocols.entries) ChoiceChip(label: Text(p.value), selected: vm.protocolFilter == p.key, onSelected: (_) => vm.filterProtocol(p.key))]),
      const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Доступность адресов проверяется одновременно. ICMP — ответ узла, TCP — ответ порта; это не подтверждение работы VPN.')),
      if (items.isEmpty && !vm.autoSelecting) Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const Icon(Icons.vpn_key_outlined, size: 48), const SizedBox(height: 12),
        const Text('Автоподбор или свой сервер', style: TextStyle(fontSize: 20)),
        const Text('ИИ-подбор выше сам загрузит базу и проверит серверы. Для ручного подключения можно импортировать свой ключ.'),
        const SizedBox(height: 12), FilledButton(onPressed: vm.busy ? null : _add, child: const Text('Добавить свой сервер')),
      ]))),
      for (final server in items) Card(child: ListTile(selected: vm.selectedId == server.id, onTap: () => vm.select(server.id),
        leading: Icon(vm.activeServer?.id == server.id ? Icons.vpn_lock : Icons.dns_outlined),
        title: Text(server.name), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${protocols[server.protocol]} · ${server.country}'), LatencyIndicator(vm.health[server.id])]),
        trailing: IconButton(tooltip:'Удалить профиль', onPressed: vm.activeServer?.id == server.id ? null : () async {
          final yes = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Удалить сервер?'),
            content: Text(server.name), actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Отмена')),
              FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Удалить'))]));
          if(yes==true) { vm.select(server.id); await vm.removeSelected(); }
        }, icon: const Icon(Icons.delete_outline)))),
    ]))));
  });
}

