import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'core/server_monitor.dart';
import 'data/profile_store.dart';
import 'platform/android_engine.dart';
import 'platform/windows_engine.dart';
import 'package:window_manager/window_manager.dart';
import 'ui/home_page.dart';
import 'ui/quiet_theme.dart';
import 'viewmodels/vpn_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  // Remove only the obsolete public OpenVPN cache, never private profiles.
  for (final name in ['catalog.json', 'catalog.json.tmp']) {
    final file = File('${support.path}/$name');
    if (await file.exists()) await file.delete();
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setSize(const Size(480, 850));
    await windowManager.center();
  }
  final vm = VpnViewModel(Platform.isWindows ? WindowsEngine() : AndroidEngine(), ProfileStore(), ServerMonitor());
  runApp(MaterialApp(debugShowCheckedModeBanner: false, title: 'Quiet VPN',
    theme: quietTheme,
    home: HomePage(vm)));
}
