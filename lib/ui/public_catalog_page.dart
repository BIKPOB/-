import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/server_monitor.dart';
import '../data/public_catalog.dart';
import '../viewmodels/vpn_view_model.dart';
import 'latency_indicator.dart';

class PublicCatalogPage extends StatefulWidget {
  const PublicCatalogPage(this.vm, {super.key});
  final VpnViewModel vm;
  @override State<PublicCatalogPage> createState() => _PublicCatalogPageState();
}
class _PublicCatalogPageState extends State<PublicCatalogPage> {
  final monitor = ServerMonitor();
  PublicCatalogResult? result;
  final health = <String, HealthResult>{};
  String protocol = 'vless';
  String? error;
  bool loading = false, probing = false, adding = false;
  @override void initState() { super.initState(); refresh(); }
  @override void dispose() { monitor.cancel(); super.dispose(); }
  Future<void> refresh() async {
    if (loading || adding) return;
    monitor.cancel();
    setState(() { loading = true; probing = false; error = null; });
    try {
      final loaded = await PublicCatalog().load();
      if (mounted) setState(() { result = loaded; health.clear(); });
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось загрузить каталог. Попробуйте обновить позже.');
    } finally { if (mounted) setState(() => loading = false); }
  }
  Future<void> probe() async {
    if (probing || loading || result == null) return;
    setState(() => probing = true);
    await monitor.sample(result!.servers, onResult: (id, value) {
      if (mounted) setState(() => health[id] = value);
    });
    if (mounted) setState(() => probing = false);
  }
  Future<void> add(VpnServer server) async {
    if (adding) return;
    setState(() { adding = true; error = null; });
    try {
      await widget.vm.importProfile(server.profile, server.name, 'Публичный · ${PublicCatalog.source}');
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
        const Text('Общедоступные серверы сторонних владельцев: доступность и скорость могут меняться. Пинг не подтверждает работу VPN.'),
        if (result != null) Text(result!.bundled ? 'Резервная база от 10.10.2026: источник обновления недоступен.' : 'База обновлена при открытии · ${PublicCatalog.source}'),
        if (result != null) Text('Совместимых: ${result!.servers.length}. Неподдерживаемых или некорректных: ${result!.skipped}.'),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Wrap(spacing: 8, children: [
          ChoiceChip(label: const Text('VLESS'), selected: protocol == 'vless', onSelected: (_) => setState(() => protocol = 'vless')),
          ChoiceChip(label: const Text('Shadowsocks'), selected: protocol == 'shadowsocks', onSelected: (_) => setState(() => protocol = 'shadowsocks')),
          TextButton(onPressed: loading || probing || result == null ? null : probe, child: Text(probing ? 'Проверка…' : 'Проверить пинг всех')),
        ]),
      ])),
      Expanded(child: items.isEmpty ? Center(child: Text(loading ? 'Загрузка базы…' : 'Нет совместимых серверов этого протокола')) : ListView.builder(
        itemCount: items.length, itemBuilder: (context, index) {
          final server = items[index];
          return ListTile(title: Text(server.name), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Порт ${server.port}'), LatencyIndicator(health[server.id]),
          ]), trailing: TextButton(onPressed: adding ? null : () => add(server), child: const Text('Добавить')));
        })),
    ]));
  }
}
