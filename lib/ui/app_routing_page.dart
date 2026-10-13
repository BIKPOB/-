import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppRoutingPage extends StatefulWidget {
  const AppRoutingPage({super.key, required this.vpnActive});
  final bool vpnActive;
  @override State<AppRoutingPage> createState() => _AppRoutingPageState();
}
class _AppRoutingPageState extends State<AppRoutingPage> {
  static const channel = MethodChannel('quietvpn/app-routing');
  List<Map<String, dynamic>> apps = [];
  Set<String> selected = {};
  bool loading = true, saving = false, system = false;
  String query = '';
  String? error;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final list = await channel.invokeListMethod<dynamic>('list') ?? [];
      final saved = await channel.invokeListMethod<String>('selected') ?? [];
      if (!mounted) return;
      setState(() { apps = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        selected = saved.toSet(); loading = false; });
    } catch (_) { if (mounted) setState(() { loading = false; error = 'Не удалось загрузить приложения. Откройте экран повторно.'; }); }
  }
  Future<void> _save() async {
    setState(() { saving = true; error = null; });
    try {
      await channel.invokeListMethod<String>('save', {'packages': selected.toList()..sort()});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.vpnActive
        ? 'Сохранено. Отключите и снова подключите VPN, чтобы применить список.'
        : 'Сохранено. Список применится при подключении VPN.')));
      Navigator.pop(context);
    } catch (_) { if (mounted) setState(() { saving = false; error = 'Не удалось сохранить. Если приложение удалено, откройте список повторно.'; }); }
  }
  @override Widget build(BuildContext context) {
    final visible = apps.where((a) => (system || a['system'] != true || selected.contains(a['package'])) &&
      ('${a['name']} ${a['package']}').toLowerCase().contains(query.toLowerCase())).toList();
    return Scaffold(resizeToAvoidBottomInset: false, appBar: AppBar(title: const Text('В обход VPN'), actions: [
      TextButton(onPressed: loading || saving || (error != null && apps.isEmpty) ? null : _save,
        child: Text(saving ? 'Сохранение…' : 'Сохранить')),
    ]), body: Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Отмеченные приложения будут подключаться к интернету напрямую. Остальные — через VPN. Список хранится на телефоне.'),
        if (widget.vpnActive) const Text('После сохранения переподключите VPN, чтобы применить изменения.'),
        const Text('При включённой в Android блокировке соединений без VPN обход может быть недоступен.'),
        const SizedBox(height: 12),
        TextField(enabled: !loading && !saving, decoration: const InputDecoration(labelText: 'Найти приложение', prefixIcon: Icon(Icons.search)),
          onChanged: (value) => setState(() => query = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Показать системные приложения'), value: system,
          onChanged: saving ? null : (value) => setState(() => system = value)),
        Row(children: [Expanded(child: Text('В обход VPN: ${selected.length}')),
          TextButton(onPressed: loading || saving ? null : () => setState(selected.clear), child: const Text('Снять все'))]),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ])),
      if (loading) const LinearProgressIndicator(),
      Expanded(child: loading ? const SizedBox.shrink() : visible.isEmpty
        ? const Center(child: Text('Приложения не найдены'))
        : ListView.builder(itemCount: visible.length, itemBuilder: (context, index) {
          final app = visible[index], name = app['package'] as String;
          final group = apps.where((a) => a['uid'] == app['uid']).map((a) => a['package'] as String).toList();
          return CheckboxListTile(value: selected.contains(name), title: Text(app['name'] as String),
            subtitle: Text('$name${group.length > 1 ? '\nОбщий сетевой доступ: выбор применяется к ${group.length} приложениям' : ''}'),
            onChanged: saving ? null : (value) => setState(() {
              if (value == true) { selected.addAll(group); } else { selected.removeAll(group); }
            }));
        })),
    ]));
  }
}
