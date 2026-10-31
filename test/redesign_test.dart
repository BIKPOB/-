import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/data/public_catalog.dart';
import 'package:quiet_vpn/core/server_monitor.dart';
import 'package:quiet_vpn/ui/home_page.dart';
import 'package:quiet_vpn/ui/quiet_theme.dart';
import 'package:quiet_vpn/viewmodels/vpn_view_model.dart';
import 'view_model_test.dart'
    show ControlledEngine, EmptyProfiles, MemoryProfiles, IdleBaselineMonitor;

class PreviewViewModel extends VpnViewModel {
  PreviewViewModel(super.engine, super.store, super.monitor, {
    super.baselineMonitor, super.catalogLoader, super.networkReader,
  });
  @override
  bool get searching => autoSelecting;
}

final previewKey = GlobalKey();
Future<void> capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Bahnschrift')
      ..addFont(rootBundle.load('assets/fonts/Bahnschrift.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  testWidgets('empty power opens error, learning lives inside settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final engine = ControlledEngine();
    final vm = PreviewViewModel(
      engine,
      EmptyProfiles(),
      ServerMonitor(
        probe: (_) async => const HealthResult(Reachability.reachable, 1),
      ),
      baselineMonitor: IdleBaselineMonitor(),
      catalogLoader: () async => const PublicCatalogResult([], false, 0),
      networkReader: () async => 'wifi',
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: quietTheme,
          home: HomePage(vm),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await capture(tester, 'main');
    final dock = tester.getRect(find.byKey(const ValueKey('main-dock')));
    expect(dock.bottom, 844);
    expect(tester.getRect(find.byKey(const ValueKey('dock-frame'))).bottom, greaterThan(844));
    final settings = tester.getRect(find.byKey(const ValueKey('ai-settings-button')));
    final power = tester.getRect(find.byKey(const ValueKey('power-button')));
    expect(power.width / settings.height, closeTo(56.556 / 22.958, .01));
    expect(power.top, closeTo(settings.top, 1));
    expect(settings.right, lessThan(power.left));
    expect(tester.widget<Text>(find.text('Информация')).style!.color, quietNavy);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Выбор сервера'));
    await tester.pumpAndSettle();
    await capture(tester, 'servers-phone');
    final panel = tester.widgetList<Container>(find.byType(Container)).firstWhere(
      (w) => w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == quietGreen);
    final decoration = panel.decoration! as BoxDecoration;
    expect(decoration.borderRadius, const BorderRadius.vertical(top: Radius.circular(24)));
    expect(tester.getRect(find.byWidget(panel)).bottom, 844);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    final messageCount = vm.messages.length;
    vm.autoSelecting = true;
    vm.searchProgress.start(false, DateTime.now().subtract(const Duration(seconds: 10)));
    for (var second = 1; second <= 15; second++) {
      vm.autoStatus = 'Параллельная проверка HTTPS: $second/100 с';
      vm.filterProtocol(null);
    }
    expect(vm.messages.length, messageCount);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await capture(tester, 'connecting');
    vm.autoSelecting = false;
    vm.autoStatus = null;
    vm.filterProtocol(null);
    await tester.pumpAndSettle();
    expect(find.text('Обход'), findsOneWidget);
    expect(find.byTooltip('Выбор сервера'), findsOneWidget);
    expect(find.text('Информация'), findsOneWidget);
    expect(find.text('Обучение ИИ'), findsNothing);
    await tester.tap(find.byTooltip('Подключить VPN'));
    await tester.pumpAndSettle();
    expect(
      find.text('Выберите сервер для подключения или начните ИИ поиск'),
      findsOneWidget,
    );
    await capture(tester, 'error');
    expect(engine.connects, 0);
    await tester.tap(find.byTooltip('Настройки ИИ-поиска'));
    await tester.pumpAndSettle();
    await capture(tester, 'settings');
    expect(find.byTooltip('Обучение ИИ'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await engine.dispose();
  });
  testWidgets('server list only appears in server panel', (tester) async {
    final engine = ControlledEngine();
    final vm = PreviewViewModel(
      engine,
      MemoryProfiles(),
      ServerMonitor(
        probe: (_) async => const HealthResult(Reachability.reachable, 1),
      ),
      baselineMonitor: IdleBaselineMonitor(),
      catalogLoader: () async => const PublicCatalogResult([], false, 0),
      networkReader: () async => 'wifi',
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: quietTheme,
          home: HomePage(vm),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('fixture'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Выбор сервера'));
    await tester.tap(find.byTooltip('Выбор сервера'));
    await tester.pumpAndSettle();
    await capture(tester, 'servers');
    expect(find.text('fixture'), findsOneWidget);
    await tester.tap(find.text('fixture'));
    await tester.pumpAndSettle();
    expect(find.text('fixture'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await engine.dispose();
  });
}
