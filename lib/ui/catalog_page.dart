import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import '../platform/runtime_manager.dart';
import '../viewmodels/vpn_view_model.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage(this.vm, {super.key});
  final VpnViewModel vm;
  @override State<CatalogPage> createState() => _CatalogPageState();
}
class _CatalogPageState extends State<CatalogPage> {
  late final runtime = RuntimeManager(Directory('${widget.vm.catalog.cacheFile.parent.path}/runtime-cache'));
  @override void initState() { super.initState(); runtime.refresh(); }
  @override void dispose() { runtime.dispose(); super.dispose(); }
  Future<void> _source(String url) async {
    try {
      if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) throw StateError('open');
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть сайт источника')));
    }
  }
  String _size(int bytes) => bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(0)} КБ' : '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';
  Future<void> _clear() async {
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Очистить кэш базы?'),
      content: const Text('Удалятся скачанные публичные профили. Ваши импортированные профили, пароли и активное подключение сохранятся.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Очистить'))]));
    if (accepted == true) await widget.vm.clearCatalogCache();
  }
  @override Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.vm, runtime]), builder: (context, _) {
      final vm = widget.vm;
      final regions = vm.servers.map((s) => s.country).toSet().toList()..sort();
      return PopScope(canPop: !runtime.busy, child: Scaffold(
        appBar: AppBar(title: const Text('База и протоколы')),
        body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('База регионов · VPN Gate', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('${vm.servers.where((s) => s.source == 'VPN Gate').length} публичных профилей · ${_size(vm.cacheBytes)} в кэше'),
                Text(vm.catalogDate == null ? 'База ещё не загружена' : 'Обновлена: ${vm.catalogDate!.toLocal().toString().substring(0, 16)}'),
                Text(vm.autoRefresh ? 'Автообновление каждые 15 минут, пока приложение открыто' : 'Автообновление приостановлено до следующей загрузки'),
                const SizedBox(height: 8),
                const Text('Профили OpenVPN скачиваются вместе с базой. Отдельные файлы с сайта не нужны. Кэш используется до 24 часов.'),
                if (vm.message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(vm.message!)),
                if (vm.refreshing) const LinearProgressIndicator(),
                Wrap(spacing: 8, children: [
                  FilledButton.icon(onPressed: vm.refreshing ? null : () => vm.refresh(force: true),
                    icon: const Icon(Icons.download), label: Text(vm.cacheBytes == 0 ? 'Скачать базу' : 'Обновить базу')),
                  TextButton.icon(onPressed: vm.refreshing || vm.cacheBytes == 0 ? null : _clear,
                    icon: const Icon(Icons.delete_outline), label: const Text('Очистить кэш')),
                ]),
              ]))),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('OpenVPN', style: Theme.of(context).textTheme.titleLarge),
                Text(Platform.isAndroid ? 'Движок встроен в приложение' : runtime.installed ? 'Движок установлен в Windows' : 'Нужны движок и сетевой драйвер'),
                if (Platform.isAndroid) const Text('Движок собран из обновлённых исходников OpenVPN for Android.'),
                if (Platform.isWindows) ...[
                  const Text('Официальный OpenVPN 2.7.7. Загрузка и проверка подписи выполняются здесь. Установка изменяет систему и добавляет драйвер.'),
                  if (runtime.message != null) Text(runtime.message!),
                  if (runtime.busy) LinearProgressIndicator(value: runtime.total > 0 && runtime.downloaded < runtime.total ? runtime.downloaded / runtime.total : null),
                  Wrap(spacing: 8, children: [
                    FilledButton(onPressed: runtime.busy || vm.canDisconnect || vm.busy ? null : runtime.downloadAndInstall,
                      child: Text(runtime.installed ? 'Обновить движок' : 'Скачать и установить')),
                    TextButton(onPressed: runtime.busy || runtime.cacheBytes == 0 ? null : runtime.clearCache,
                      child: Text('Очистить установщик (${_size(runtime.cacheBytes)})')),
                  ]),
                ],
              ]))),
            ListTile(leading: const Icon(Icons.extension_outlined), title: const Text('WireGuard и AmneziaWG'),
              subtitle: Text(Platform.isAndroid
                ? 'Движки встроены. Добавьте .conf или вставьте конфигурацию кнопкой на главном экране. Нужны ключи от владельца сервера; VPN Gate их не предоставляет.'
                : 'Новые движки пока доступны только в Android.')),
            if (Platform.isAndroid) ...[
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text(
                'Готовая конфигурация выдаётся владельцем сервера. Для WireGuard можно получить .conf в личном кабинете Proton VPN; для AmneziaWG — экспортировать .conf своего сервера. Автоматической выдачи ключей в Quiet VPN нет.')),
              Wrap(spacing: 8, children: [
                TextButton(onPressed: () => _source('https://protonvpn.com/support/wireguard-configurations'), child: const Text('Получить WireGuard .conf')),
                TextButton(onPressed: () => _source('https://docs.amnezia.org/documentation/instructions/use-amneziawg-app/'), child: const Text('Получить AmneziaWG .conf')),
              ]),
            ],
            const Divider(),
            Text('Регионы', style: Theme.of(context).textTheme.titleLarge),
            ...regions.map((region) => ListTile(leading: const Icon(Icons.public), title: Text(region),
              subtitle: Text('${vm.servers.where((s) => s.country == region).length} профилей'),
              trailing: const Icon(Icons.chevron_right), onTap: runtime.busy ? null : () { vm.filterCountry(region); Navigator.pop(context); })),
          ]))),
      ));
    });
}
