import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/traffic.dart';
import '../viewmodels/vpn_view_model.dart';
import 'catalog_page.dart';
import 'latency_indicator.dart';

class HomePage extends StatefulWidget {
  const HomePage(this.vm, {super.key});
  final VpnViewModel vm;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  VpnViewModel get vm => widget.vm;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); unawaited(vm.initialize()); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
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
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); vm.dispose(); super.dispose(); }
  void _add() => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CatalogPage(vm)));
  Future<void> _diagnostics() async {
    final native = await const MethodChannel('quietvpn/diagnostics').invokeMethod<String>('report') ?? '';
    final report = '$native\nПротокол: ${vm.activeServer?.protocol ?? vm.selected?.protocol ?? '—'}\n'
      'Состояние: ${vm.state.name}\nЭтап: ${vm.connectionStage ?? '—'}\n${vm.message ?? ''}\n'
      'Интернет и качество подтверждены: ${vm.connectionVerified}\n'
      'Сеть: ${vm.networkContext.label} · обучающих замеров: ${vm.learningSamples}\n'
      'ИИ: ${vm.autoStatus ?? 'не запускался'}\n${vm.autoAttemptReports.join('\n\n')}';
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('Диагностика'),
      content: SingleChildScrollView(child: SelectableText(report)), actions: [
        TextButton(onPressed: () async { await Clipboard.setData(ClipboardData(text: report)); }, child: const Text('Копировать')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]));
  }
  Future<void> _deepSearch() async {
    final proceed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Глубокий подбор'),
      content: const Text('Приложение изучит текущую сеть и сравнит до 12 VPN-профилей: DNS, HTTPS и до трёх загрузок по 256 КиБ на каждый. Затем повторно подключит лучший прошедший проверку вариант. Это может занять несколько минут, а при таймаутах — значительно дольше и около 12 МиБ тестовых данных плюс служебный трафик.\n\nДля мобильной сети Android запросит доступ к состоянию телефона: он нужен для типа связи и уровня сигнала. Для Wi-Fi используются сигнал и диапазон. Геолокация, звонки и содержимое трафика не собираются. Данные обучения остаются на телефоне. При отказе от разрешения часть параметров будет недоступна.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Изучить сеть и начать'))]));
    if (proceed != true || !mounted) return;
    await vm.enableNetworkAnalysis();
    if (!mounted) return;
    await vm.autoConnect(deep: true);
  }
  Future<void> _learning() async {
    await showDialog<void>(context: context, builder: (c) => AlertDialog(
      title: Text('Опыт нейросети: ${vm.learningSamples}'),
      content: SizedBox(width: 500, child: SingleChildScrollView(child: Text(
        vm.learningJournal.isEmpty ? 'Пока нет измерений. Модель начинает без готовых знаний о ваших серверах.' :
        vm.learningJournal.reversed.take(30).map((e) =>
          '${e['time']} · ${e['network']} · ${e['protocol']}\n${switch (e['outcome']) { 'verified' => 'Проверено', 'slow_or_unstable' => 'Медленно или повторный замер не прошёл', 'network_uncertain' => 'Сеть не определена', _ => 'Соединение не подтверждено' }} · ${e['bytesPerSecond'] == null ? 'скорость не измерена' : '${((e['bytesPerSecond'] as num) / 1024).round()} КиБ/с'}').join('\n\n')))),
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
      IconButton(tooltip: 'Проверить пинг', onPressed: vm.refreshLatency, icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'Обучение', onPressed: _learning, icon: const Icon(Icons.psychology_outlined)),
      IconButton(tooltip: 'Диагностика', onPressed: _diagnostics, icon: const Icon(Icons.bug_report_outlined)),
    ]), floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Добавить сервер')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: ListView(padding: const EdgeInsets.fromLTRB(16,16,16,100), children: [
      Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(switch(vm.state) { ConnectionState.connected => vm.connectionVerified ? 'Подключено · проверено' : 'Туннель включён · есть ограничения', ConnectionState.connecting => 'Подключение…',
          ConnectionState.error => 'Не удалось подключиться', _ => 'VPN выключен' }, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8), Text(vm.activeServer?.name ?? vm.selected?.name ?? 'Добавьте первый сервер'),
        Text('↓ ${formatTrafficRate(vm.traffic.download)}   ↑ ${formatTrafficRate(vm.traffic.upload)}'),
        if (vm.message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(vm.message!)),
        FilledButton.icon(onPressed: vm.autoSelecting || vm.busy || !vm.ready || (!vm.canDisconnect && vm.selected == null) ? null : () async {
          if (vm.canDisconnect) { await vm.disconnect(); } else { await vm.connect(null); }
        }, icon: Icon(vm.canDisconnect ? Icons.stop : Icons.power_settings_new), label: Text(vm.canDisconnect ? 'Отключить' : 'Подключить')),
        OutlinedButton.icon(onPressed: !vm.ready || vm.busy && !vm.autoSelecting || vm.canDisconnect && !vm.autoSelecting ? null
          : () async { if (vm.autoSelecting) { await vm.cancelAutoSelection(); } else { await _deepSearch(); } },
          icon: Icon(vm.autoSelecting ? Icons.stop : Icons.auto_awesome),
          label: Text(vm.autoSelecting ? 'Остановить подбор' : 'Глубокий ИИ-подбор')),
        const Text('Нейросеть учится на измерениях этой сети. Сравнивает WireGuard, VLESS и Shadowsocks по загрузке и повторяемости результатов. До 12 кандидатов. Во время подбора оставьте приложение открытым.'),
        if (vm.autoStatus != null) Text(vm.networkContext.label),
        if (vm.autoStatus != null) Text(vm.autoStatus!),
        if (vm.autoPlan.isNotEmpty) Text(vm.autoPlan),
        if (vm.busy || vm.state == ConnectionState.connecting) const LinearProgressIndicator(),
      ]))),
      const SizedBox(height: 16), Text('Мои серверы', style: Theme.of(context).textTheme.titleLarge),
      Wrap(spacing: 6, children: [ChoiceChip(label: const Text('Все'), selected: vm.protocolFilter == null, onSelected: (_) => vm.filterProtocol(null)),
        for (final p in protocols.entries) ChoiceChip(label: Text(p.value), selected: vm.protocolFilter == p.key, onSelected: (_) => vm.filterProtocol(p.key))]),
      const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Пинг всех адресов проверяется одновременно. ICMP — ответ узла, TCP — ответ порта; это не подтверждение работы VPN.')),
      if (items.isEmpty) Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const Icon(Icons.vpn_key_outlined, size: 48), const SizedBox(height: 12),
        const Text('Выберите сервер', style: TextStyle(fontSize: 20)),
        const Text('Откройте публичную базу WireGuard/VLESS/Shadowsocks или импортируйте собственный ключ.'),
        const SizedBox(height: 12), FilledButton(onPressed: _add, child: const Text('Выбрать протокол')),
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
