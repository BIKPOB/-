import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'core/server_monitor.dart';
import 'data/profile_store.dart';
import 'platform/android_engine.dart';
import 'ui/home_page.dart';
import 'viewmodels/vpn_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  // Remove only the obsolete public OpenVPN cache, never private profiles.
  for (final name in ['catalog.json', 'catalog.json.tmp']) {
    final file = File('${support.path}/$name');
    if (await file.exists()) await file.delete();
  }
  final vm = VpnViewModel(AndroidEngine(), ProfileStore(), ServerMonitor());
  runApp(MaterialApp(debugShowCheckedModeBanner: false, title: 'Quiet VPN',
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B61))),
    home: HomePage(vm)));
}
