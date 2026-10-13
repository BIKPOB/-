import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';
import '../core/profile_policy.dart';

class WindowsBrowserPage extends StatefulWidget {
  const WindowsBrowserPage(this.url, {super.key});
  final String url;
  @override State<WindowsBrowserPage> createState() => _WindowsBrowserPageState();
}
class _WindowsBrowserPageState extends State<WindowsBrowserPage> {
  final controller = WebviewController();
  final address = TextEditingController();
  final subscriptions = <StreamSubscription<dynamic>>[];
  String? error;
  bool ready = false, importing = false;
  static Future<void>? _environment;
  @override void initState() { super.initState(); address.text = widget.url; unawaited(_initialize()); }
  Future<void> _initialize() async {
    try {
      _environment ??= (() async {
        final support = await getApplicationSupportDirectory();
        await WebviewController.initializeEnvironment(userDataPath: '${support.path}\\browser');
      })();
      await _environment;
      await controller.initialize();
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      subscriptions.add(controller.url.listen((url) { if (mounted) address.text = url; }));
      subscriptions.add(controller.webMessage.listen((value) {
        if (value is String && value.length <= ProfilePolicy.maxBytes) unawaited(_receive(value));
      }));
      await controller.addScriptToExecuteOnDocumentCreated(r'''
        document.addEventListener('click',e=>{
          const a=e.target.closest&&e.target.closest('a'); if(!a)return;
          const v=a.getAttribute('href')||'';
          if(/^(vless|ss|wireguard):\/\//i.test(v)) {
            e.preventDefault();e.stopPropagation();window.chrome.webview.postMessage(v);
          }
        },true);
      ''');
      await controller.loadUrl(widget.url);
      if (mounted) setState(() { ready = true; });
    } catch (_) {
      if (mounted) setState(() { error = 'Встроенный браузер недоступен. Установите Microsoft Edge WebView2 Runtime или откройте сайт во внешнем браузере и импортируйте ключ/файл.'; });
    }
  }
  Future<void> _receive(String value) async {
    if (importing || !mounted) return;
    importing = true;
    try {
      final parsed = ProfilePolicy.parse(value);
      if (mounted) Navigator.pop(context, parsed.text);
    } catch (_) { if (mounted) setState(() { error = 'Совместимый профиль не найден. Используйте ключ или файл .conf.'; }); }
    finally { importing = false; }
  }
  Future<void> _capture() async {
    try {
      final raw = await controller.executeScript(r'''JSON.stringify([
        ...Array.from(document.querySelectorAll('a[href]')).map(e=>e.getAttribute('href')),
        ...Array.from(document.querySelectorAll('textarea,input,pre,code')).map(e=>e.value||e.textContent)
      ].filter(v=>v&&v.length<=131072).slice(0,200))''');
      dynamic decoded = raw;
      for (var i = 0; i < 2 && decoded is String; i++) { decoded = jsonDecode(decoded); }
      final candidates = <String>[];
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! String) continue;
          try { final profile = ProfilePolicy.parse(item.trim()).text; if (!candidates.contains(profile)) candidates.add(profile); } catch (_) { }
        }
      }
      if (!mounted) return;
      if (candidates.isEmpty) { setState(() { error = 'На странице нет совместимых ключей. Скопируйте ключ или скачайте .conf и импортируйте файл.'; }); return; }
      final selected = await showDialog<String>(context: context, builder: (c) => SimpleDialog(
        title: const Text('Выберите профиль'), children: [for (final text in candidates)
          SimpleDialogOption(onPressed: () => Navigator.pop(c, text), child: Text('${ProfilePolicy.parse(text).protocol} · ${ProfilePolicy.parse(text).host}'))]));
      if (selected != null) await _receive(selected);
    } catch (_) { if (mounted) setState(() { error = 'Не удалось прочитать профили со страницы'; }); }
  }
  Future<void> _navigate() async {
    final uri = Uri.tryParse(address.text);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      setState(() { error = 'Введите HTTPS-адрес'; }); return;
    }
    await controller.loadUrl(uri.toString());
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Источник конфигураций')),
    body: Column(children: [
      Row(children: [IconButton(onPressed: ready ? controller.goBack : null, icon: const Icon(Icons.arrow_back)),
        Expanded(child: TextField(controller: address, onSubmitted: (_) => _navigate())),
        IconButton(onPressed: ready ? _navigate : null, icon: const Icon(Icons.arrow_forward)),
        IconButton(onPressed: ready ? controller.reload : null, icon: const Icon(Icons.refresh))]),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: ready ? _capture : null, child: const Text('Импорт со страницы')),
        TextButton(onPressed: () async { final value = await Clipboard.getData('text/plain'); if (value?.text != null) await _receive(value!.text!); }, child: const Text('Вставить ключ')),
        TextButton(onPressed: ready ? () async { await controller.clearCookies(); await controller.clearCache(); } : null, child: const Text('Очистить данные сайта')),
        TextButton(onPressed: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication), child: const Text('Открыть снаружи'))]),
      if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
      if (ready) Expanded(child: Webview(controller, permissionRequested: (_, _, _) async => WebviewPermissionDecision.deny))
      else if (error == null) const LinearProgressIndicator(),
    ]));
  @override void dispose() {
    for (final sub in subscriptions) { unawaited(sub.cancel()); }
    unawaited(controller.dispose()); address.dispose(); super.dispose();
  }
}
