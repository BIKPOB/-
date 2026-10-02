import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'core/server_monitor.dart';
import 'data/catalog_repository.dart';
import 'data/profile_store.dart';
import 'platform/android_engine.dart';
import 'platform/windows_engine.dart';
import 'platform/vpn_engine.dart';
import 'ui/home_page.dart';
import 'viewmodels/vpn_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }
  final support = await getApplicationSupportDirectory();
  final VpnEngine engine;
  if (Platform.isAndroid) { engine = AndroidEngine(); }
  else if (Platform.isWindows) { engine = WindowsEngine(Directory('${support.path}/sessions')); }
  else { throw UnsupportedError('Поддерживаются Windows и Android'); }
  const catalogUrl = String.fromEnvironment('CATALOG_URL', defaultValue: 'https://www.vpngate.net/api/iphone/');
  final vm = VpnViewModel(engine, CatalogRepository(File('${support.path}/catalog.json'),
    endpoint: Uri.parse(catalogUrl)), ProfileStore(), ServerMonitor());
  runApp(MaterialApp(debugShowCheckedModeBanner: false, title: 'Quiet VPN',
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B61))),
    home: HomePage(vm)));
}
