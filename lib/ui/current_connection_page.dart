import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CurrentConnectionPage extends StatefulWidget {
  const CurrentConnectionPage({super.key});
  @override
  State<CurrentConnectionPage> createState() => _CurrentConnectionPageState();
}

class _CurrentConnectionPageState extends State<CurrentConnectionPage> {
  static const _channel = MethodChannel('quietvpn/current-connection');
  String _label = 'Без VPN';
  String _report = '';
  bool _running = false;
  Future<void> _run() async {
    setState(() { _running = true; _report = ''; });
    try {
      final report = await _channel.invokeMethod<String>('run', {'label': _label});
      if (mounted) setState(() => _report = report ?? 'Нет результата');
    } on PlatformException catch (e) {
      if (mounted) setState(() => _report = 'Тест не завершён: ${e.code}');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
  Future<void> _share() async {
    try {
      await _channel.invokeMethod<void>('share', {'text': _report});
    } on PlatformException {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отправка недоступна. Скопируйте отчёт.')));
    }
  }
  @override
  void dispose() {
    _channel.invokeMethod<void>('cancel').catchError((Object _) {});
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Текущее соединение')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Тест не включает VPN Quiet. Для сравнения выполните его без VPN, затем включите Turbo и повторите. Quiet не должен быть в исключениях Turbo. Выбранная метка — ваше описание, а не определение VPN.\n\nДо 3 МиБ загрузки плюс служебный трафик, бюджет около 75 секунд. В отчёте будет выходной IP. Просмотрите его перед отправкой.'),
      const SizedBox(height: 16),
      DropdownButton<String>(value: _label, isExpanded: true,
        items: ['Без VPN', 'Turbo VPN', 'Другой VPN'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: _running ? null : (v) => setState(() => _label = v!)),
      FilledButton(onPressed: _running ? null : _run, child: const Text('Проверить текущее соединение')),
      if (_running) ...[
        const LinearProgressIndicator(),
        const Text('Проверяются HTTPS, выходной IP и три загрузки. Оставьте приложение открытым.'),
        TextButton(onPressed: () => _channel.invokeMethod<void>('cancel'), child: const Text('Остановить')),
      ],
      if (_report.isNotEmpty) ...[
        SelectableText(_report),
        FilledButton.icon(onPressed: _share, icon: const Icon(Icons.share), label: const Text('Отправить отчёт')),
        TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: _report)), child: const Text('Копировать')),
      ],
    ]),
  );
}
