import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../core/models.dart';
import '../core/traffic.dart';
import '../core/profile_policy.dart';
import '../viewmodels/vpn_view_model.dart';
import 'catalog_page.dart';
import 'latency_indicator.dart';

class HomePage extends StatefulWidget {
  const HomePage(this.vm, {super.key});
  final VpnViewModel vm;
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> with WidgetsBindingObserver, WindowListener {
  VpnViewModel get vm => widget.vm;
  @override void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) windowManager.addListener(this);
    unawaited(vm.initialize());
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    vm.setForeground(state == AppLifecycleState.resumed);
  }
  @override void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this); vm.dispose(); super.dispose();
  }
  @override void onWindowClose() async {
    if (vm.busy) return;
    await vm.disconnect();
    if (!vm.canDisconnect) await windowManager.destroy();
  }
  void _error(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        error is FormatException ? error.message : 'Операция не выполнена')));
    }
  }
  Future<void> _import() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ovpn', 'conf'], withData: false);
      if (result == null) return;
      final file = result.files.single;
      if (file.size > ProfilePolicy.maxBytes) throw const FormatException('Лимит профиля — 128 КБ');
      if (file.path == null || await File(file.path!).length() > ProfilePolicy.maxBytes) {
        throw const FormatException('Невозможно прочитать профиль или превышен лимит 128 КБ');
      }
      final bytes = await File(file.path!).readAsBytes();
      if (!mounted) return;
      final region = await _region();
      if (region == null) return;
      await vm.importProfile(utf8.decode(bytes), file.name.replaceAll(RegExp(r'\.(ovpn|conf)$'), ''), region);
    } catch (error) { _error(error); }
  }
  Future<void> _pasteProfile() async {
    final controller = TextEditingController();
    String? text;
    try {
      text = await showDialog<String>(context: context, builder: (context) => AlertDialog(
        title: const Text('Вставить конфигурацию'),
        content: SizedBox(width: 600, child: TextField(controller: controller, minLines: 6, maxLines: 12,
          maxLength: ProfilePolicy.maxBytes, enableSuggestions: false, autocorrect: false,
          decoration: const InputDecoration(hintText: 'OpenVPN, WireGuard или AmneziaWG'))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Добавить'))]));
    } finally { controller.dispose(); }
    if (text == null || !mounted) return;
    try {
      final region = await _region();
      if (region != null) await vm.importProfile(text, 'Мой сервер', region);
    } catch (error) { _error(error); }
  }
  Future<String?> _region() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(context: context, builder: (context) => AlertDialog(
        title: const Text('Регион профиля'),
        content: TextField(controller: controller, maxLength: 60,
          decoration: const InputDecoration(hintText: 'Например, Германия')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Импорт'))],
      ));
    } finally { controller.dispose(); }
  }
  Future<Credentials?> _credentials() async {
    final user = TextEditingController();
    final password = TextEditingController();
    try {
      return await showDialog<Credentials>(context: context, builder: (context) => AlertDialog(
        title: const Text('Доступ к серверу'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: user, decoration: const InputDecoration(labelText: 'Логин')),
          TextField(controller: password, obscureText: true, enableSuggestions: false,
            autocorrect: false, decoration: const InputDecoration(labelText: 'Пароль')),
          const SizedBox(height: 12),
          const Text('Данные сохраняются в защищённом хранилище устройства.'),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, Credentials(user.text, password.text)), child: const Text('Сохранить'))],
      ));
    } finally { user.dispose(); password.dispose(); }
  }
  Future<void> _diagnostics() async {
    try {
      final report = await const MethodChannel('quietvpn/diagnostics').invokeMethod<String>('report') ?? 'Нет данных';
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (context) => AlertDialog(
        title: const Text('Диагностика сбоя'),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
          TextButton(onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (context.mounted) Navigator.pop(context);
          }, child: const Text('Копировать'))]));
    } catch (error) { _error(error); }
  }
  Future<void> _connect() async {
    try {
      if (vm.canDisconnect) { await vm.disconnect(); return; }
      final selected = vm.selected;
      if (selected == null) return;
      Credentials? auth;
      if (ProfilePolicy.parse(selected.profile).needsAuth) {
        auth = await vm.store.credentials(selected.id);
        if (auth == null && selected.source == 'VPN Gate') auth = const Credentials('vpn', 'vpn');
        auth ??= await _credentials();
        if (auth == null) return;
      }
      // The selected server may change while a dialog is open; bind the result.
      if (vm.selectedId != selected.id) return;
      await vm.connect(auth);
    } catch (error) { _error(error); }
  }
  Future<void> _editAuth() async {
    final server = vm.selected;
    if (server == null) return;
    try {
      final auth = await _credentials();
      if (auth != null) await vm.store.saveCredentials(server.id, auth);
    } catch (error) { _error(error); }
  }
  @override Widget build(BuildContext context) => ListenableBuilder(listenable: vm, builder: (context, _) {
    final countries = vm.servers.map((s) => s.country).toSet().toList()..sort();
    final items = vm.filtered;
    final label = switch (vm.state) {
      ConnectionState.connecting => 'Connecting', ConnectionState.connected => 'Connected',
      ConnectionState.disconnected => 'Disconnected', ConnectionState.error => 'Error',
    };
    return Scaffold(appBar: AppBar(title: const Text('Quiet VPN'), actions: [
      IconButton(tooltip: 'База и протоколы', onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CatalogPage(vm))), icon: const Icon(Icons.storage_outlined)),
      IconButton(tooltip: 'Обновить каталог', onPressed: vm.refreshing ? null : () => vm.refresh(force: true), icon: const Icon(Icons.refresh)),
      IconButton(tooltip: 'Вставить конфигурацию', onPressed: _pasteProfile, icon: const Icon(Icons.content_paste)),
      IconButton(tooltip: 'Импорт .ovpn / .conf', onPressed: _import, icon: const Icon(Icons.file_open_outlined)),
    ]), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: Padding(
      padding: const EdgeInsets.all(16), child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(vm.state == ConnectionState.connected ? Icons.vpn_lock : Icons.shield_outlined),
            const SizedBox(width: 12), Text(label, style: Theme.of(context).textTheme.headlineSmall)]),
          Text('↓ ${formatTrafficRate(vm.traffic.download)}   ↑ ${formatTrafficRate(vm.traffic.upload)}', semanticsLabel: 'Скорость загрузки ${formatTrafficRate(vm.traffic.download)}, выгрузки ${formatTrafficRate(vm.traffic.upload)}'),
          if (vm.activeServer != null) Text('${vm.activeServer!.country} · ${vm.activeServer!.name}'),
          if (vm.message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(vm.message!)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: vm.busy || !vm.ready || (!vm.canDisconnect && vm.selected == null) ? null : _connect,
            child: Text(vm.canDisconnect ? 'Отключить' : 'Подключить'))),
          if (vm.state == ConnectionState.connecting || vm.busy) const LinearProgressIndicator(),
        ]))),
        Wrap(spacing: 8, children: [
          TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CatalogPage(vm))), icon: const Icon(Icons.storage_outlined), label: const Text('База и протоколы')),
          TextButton(onPressed: vm.selected == null ? null : _editAuth, child: const Text('Логин / пароль')),
          if (Platform.isAndroid) TextButton.icon(onPressed: _diagnostics, icon: const Icon(Icons.bug_report_outlined), label: const Text('Диагностика сбоя')),
          if (vm.selected?.source == 'Импорт') TextButton(onPressed: () async {
            try { await vm.removeSelected(); } catch (error) { _error(error); }
          }, child: const Text('Удалить профиль')),
        ]),
        Wrap(spacing: 6, children: [
          ChoiceChip(label: const Text('Все'), selected: vm.protocolFilter == null, onSelected: (_) => vm.filterProtocol(null)),
          ...['openvpn', 'wireguard', 'amneziawg'].map((protocol) => ChoiceChip(
            label: Text({'openvpn': 'OpenVPN', 'wireguard': 'WireGuard', 'amneziawg': 'AmneziaWG'}[protocol]!),
            selected: vm.protocolFilter == protocol, onSelected: (_) => vm.filterProtocol(protocol))),
        ]),
        DropdownButtonFormField<String>(value: countries.contains(vm.country) ? vm.country : null,
          decoration: const InputDecoration(labelText: 'Регион'),
          items: [const DropdownMenuItem<String>(value: null, child: Text('Все регионы')),
            ...countries.map((c) => DropdownMenuItem(value: c, child: Text(c)))], onChanged: vm.filterCountry),
        const SizedBox(height: 8),
        Text('${items.length} серверов · ${vm.cached ? 'кэш' : 'каталог'} · пинг всех серверов одновременно'),
        const Text('ICMP — ответ узла; TCP — задержка соединения. Пинг не подтверждает работу VPN. При активном VPN измерение может идти через туннель.'),
        if (vm.refreshing) const LinearProgressIndicator(),
        ])),
        if (items.isEmpty) SliverToBoxAdapter(child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(children: [
            Text(vm.protocolFilter == 'wireguard' || vm.protocolFilter == 'amneziawg'
              ? 'Для этого протокола нет добавленных серверов. VPN Gate предоставляет только OpenVPN. Получите .conf в разделе «База и протоколы» или импортируйте свой.'
              : vm.refreshing ? 'Загрузка…' : 'Серверы не загружены. Откройте «База и протоколы» или добавьте конфигурацию.'),
            if (vm.protocolFilter == 'wireguard' || vm.protocolFilter == 'amneziawg')
              Wrap(spacing: 8, children: [
                TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CatalogPage(vm))), icon: const Icon(Icons.download), label: const Text('Получить сервер')),
                TextButton.icon(onPressed: _import, icon: const Icon(Icons.file_open_outlined), label: const Text('Импорт .conf')),
                TextButton.icon(onPressed: _pasteProfile, icon: const Icon(Icons.content_paste), label: const Text('Вставить конфигурацию')),
              ]),
          ])))
        else SliverList(delegate: SliverChildBuilderDelegate((context, index) {
            final server = items[index];
            final result = vm.health[server.id];
            return ListTile(selected: server.id == vm.selectedId, onTap: () => vm.select(server.id),
              leading: Radio<String>(value: server.id, groupValue: vm.selectedId, onChanged: (_) => vm.select(server.id)),
              title: Text('${server.country} · ${server.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${server.protocol.toUpperCase()} · ${server.source} · ${server.transport.toUpperCase()}'),
                LatencyIndicator(result),
              ]),
              trailing: server.id == vm.activeServer?.id ? const Icon(Icons.check_circle_outline) : null);
          }, childCount: items.length)),
        const SliverToBoxAdapter(child: Text('Публичные серверы могут вести журналы и исчезать из каталога.', style: TextStyle(fontSize: 12))),
      ]),
    ))));
  });
}
