import 'package:flutter/material.dart';
import '../core/site_bypass.dart';

class SiteBypassPage extends StatefulWidget {
  const SiteBypassPage({super.key, required this.host, required this.vpnActive});
  final SiteBypassHost host;
  final bool vpnActive;
  @override State<SiteBypassPage> createState() => _SiteBypassPageState();
}

class _SiteBypassPageState extends State<SiteBypassPage> {
  late final TextEditingController input;
  String? error;
  bool saving = false;
  @override void initState() {
    super.initState(); input = TextEditingController(text: widget.host.bypassSites.join('\n'));
  }
  @override void dispose() { input.dispose(); super.dispose(); }
  Future<void> save() async {
    setState(() { saving = true; error = null; });
    try {
      final sites = SiteBypass.parse(input.text);
      await widget.host.saveBypassSites(sites);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.vpnActive
        ? 'Сохранено. Переподключите VPN для применения.' : 'Список применится при подключении VPN.')));
      Navigator.pop(context);
    } on FormatException catch (e) {
      if (mounted) setState(() { saving = false; error = e.message; });
    } catch (_) {
      if (mounted) setState(() { saving = false; error = 'Не удалось сохранить список. Попробуйте ещё раз.'; });
    }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Сайты в обход VPN')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Указанные сайты открываются напрямую, с вашим обычным IP. Остальной трафик проходит через VPN. Работает с VLESS и Shadowsocks; автоподбор выберет эти протоколы.'),
        const SizedBox(height: 12),
        const Text('Вставьте домены или ссылки — по одному на строку. Путь страницы не учитывается: исключение действует на весь домен и его поддомены. Для дополнительных доменов входа, оплаты и загрузки файлов нужны отдельные записи.'),
        const SizedBox(height: 12),
        TextField(controller: input, enabled: !saving, minLines: 8, maxLines: 16,
          autocorrect: false, enableSuggestions: false,
          decoration: InputDecoration(border: const OutlineInputBorder(),
            labelText: 'Домены, ссылки или IP', hintText: 'gosuslugi.ru\nhttps://www.ozon.ru/\nyandex.ru', errorText: error, errorMaxLines: 4)),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: saving ? null : () {
            input.text = '${input.text}\ngosuslugi.ru\nyandex.ru\nmail.ru\nvk.com\nozon.ru\nwildberries.ru\nsberbank.ru\nsber.ru'.trim();
          }, child: const Text('Добавить примеры российских сервисов')),
          TextButton(onPressed: saving ? null : input.clear, child: const Text('Очистить список')),
        ]),
        const Text('DNS-запросы остаются через VPN. Если приложение скрывает домен (например, ECH), правило по домену может не сработать; такой трафик останется в VPN. IP-исключение действует только на указанный адрес.'),
        if (widget.vpnActive) const Padding(padding: EdgeInsets.only(top: 12),
          child: Text('После сохранения переподключите VPN и заново откройте сайт.')),
        const SizedBox(height: 16),
        FilledButton(onPressed: saving ? null : save,
          child: Text(saving ? 'Сохранение…' : 'Сохранить')),
      ]))),
  );
}
