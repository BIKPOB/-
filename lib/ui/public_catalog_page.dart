import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/public_catalog.dart';
import '../viewmodels/vpn_view_model.dart';
import 'latency_indicator.dart';

class PublicCatalogPage extends StatefulWidget {
  const PublicCatalogPage(this.vm, {super.key});
  final VpnViewModel vm;
  @override State<PublicCatalogPage> createState() => _PublicCatalogPageState();
}
class _PublicCatalogPageState extends State<PublicCatalogPage> {
  PublicCatalogResult? result;
  String protocol = 'vless';
  String? error;
  bool loading = false, adding = false;
  @override void initState() { super.initState(); widget.vm.addListener(update); refresh(); }
  void update() { if (mounted) setState(() {}); }
  @override void dispose() { widget.vm.removeListener(update); super.dispose(); }
  Future<void> refresh() async {
    if (loading || adding) return;
    setState(() { loading = true; error = null; });
    try {
      final loaded = await PublicCatalog().load();
      widget.vm.registerHealthCatalog(loaded.servers);
      if (mounted) setState(() { result = loaded; });
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось загрузить каталог. Попробуйте обновить позже.');
    } finally { if (mounted) setState(() => loading = false); }
  }
  Future<void> add(VpnServer server) async {
    if (adding) return;
    setState(() { adding = true; error = null; });
    try {
      await widget.vm.importProfile(server.profile, server.name, 'Публичный · ${server.source}');
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось сохранить сервер');
    } finally { if (mounted) setState(() => adding = false); }
  }
  @override Widget build(BuildContext context) {
    final items = result?.servers.where((s) => s.protocol == protocol).toList() ?? <VpnServer>[];
    return Scaffold(appBar: AppBar(title: const Text('Публичные серверы'), actions: [
      IconButton(onPressed: loading || adding ? null : refresh, tooltip: 'Обновить базу', icon: const Icon(Icons.refresh)),
    ]), body: Column(children: [
      if (loading || adding) const LinearProgressIndicator(),
      Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Выберите сервер → «Добавить» → «Подключить» на главном экране. Ссылка провайдера не нужна.'),
        const SizedBox(height: 8),
        const Text('Общедоступные серверы сторонних владельцев: доступность и скорость могут меняться. Цвет показывает результат HTTPS через сервер; полный VPN проверяется при подключении.'),
        const Text('Автообновление базы: примерно раз в 6 часов при наличии сети. Android может отложить запуск. Срок ключей задаёт провайдер.'),
        if (result != null) Text(result!.status),
        if (widget.vm.backgroundStatus != null) Text(widget.vm.backgroundStatus!),
        if (result != null) Text('Совместимых: ${result!.servers.length}. Неподдерживаемых или некорректных: ${result!.skipped}.'),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Wrap(spacing: 8, children: [
          ChoiceChip(label: const Text('WireGuard'), selected: protocol == 'wireguard', onSelected: (_) => setState(() => protocol = 'wireguard')),
          ChoiceChip(label: const Text('VLESS'), selected: protocol == 'vless', onSelected: (_) => setState(() => protocol = 'vless')),
          ChoiceChip(label: const Text('Shadowsocks'), selected: protocol == 'shadowsocks', onSelected: (_) => setState(() => protocol = 'shadowsocks')),
          TextButton(onPressed: loading || result == null ? null : widget.vm.refreshLatency, child: const Text('Проверить подключение всех')),
        ]),
      ])),
      Expanded(child: items.isEmpty ? Center(child: Text(loading ? 'Загрузка базы…' : 'Нет совместимых серверов этого протокола')) : ListView.builder(
        itemCount: items.length, itemBuilder: (context, index) {
          final server = items[index];
          return ListTile(title: Text(server.name), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(server.source), LatencyIndicator(widget.vm.serverHealth(server)),
          ]), trailing: TextButton(onPressed: adding ? null : () => add(server), child: const Text('Добавить')));
        })),
    ]));
  }
}
