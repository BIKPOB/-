import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart' as model;
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/data/profile_store.dart';
import 'package:quiet_vpn/platform/vpn_engine.dart';
import 'package:quiet_vpn/ui/catalog_page.dart';
import 'package:quiet_vpn/viewmodels/vpn_view_model.dart';
class IdleEngine implements VpnEngine {
  @override Stream<model.EngineEvent> get events => const Stream.empty();
  @override Future<void> initialize() async {}
  @override Future<void> connect(model.VpnServer server, model.Credentials? credentials) async {}
  @override Future<void> disconnect() async {}
  @override Future<void> reconcile() async {}
  @override Future<void> dispose() async {}
}
void main() {
  testWidgets('each protocol opens interactive browser, import and parameter tabs on a phone', (tester) async {
    tester.view.physicalSize=const Size(360,800); tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final vm=VpnViewModel(IdleEngine(),ProfileStore(),ServerMonitor());
    addTearDown(vm.dispose);
    for(final protocol in protocols.keys) {
      await tester.pumpWidget(MaterialApp(home:AddServerPage(vm,protocol,key:ValueKey(protocol))));
      await tester.pumpAndSettle();
      expect(find.text('Открыть интерактивный браузер'),findsOneWidget);
      await tester.tap(find.text('Ключ / файл'));await tester.pumpAndSettle();
      expect(find.text('Проверить и добавить'),findsOneWidget);
      await tester.tap(find.text('Параметры'));await tester.pumpAndSettle();
      expect(find.text('Адрес сервера'),findsOneWidget);
      expect(tester.takeException(),isNull);
    }
  });
}
