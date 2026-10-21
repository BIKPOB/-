import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/ui/current_connection_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('explicit test reports and shares only after user action', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('quietvpn/current-connection'), (call) async {
        calls.add(call);
        return call.method == 'run' ? 'Тестовый отчёт' : null;
      });
    await tester.pumpWidget(const MaterialApp(home: CurrentConnectionPage()));
    expect(calls, isEmpty);
    await tester.tap(find.text('Проверить текущее соединение'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'run');
    expect(calls.single.arguments['label'], 'Без VPN');
    expect(find.text('Тестовый отчёт'), findsOneWidget);
    await tester.ensureVisible(find.text('Отправить отчёт'));
    await tester.tap(find.text('Отправить отчёт'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'share');
    expect(calls.last.arguments['text'], 'Тестовый отчёт');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.last.method, 'cancel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('quietvpn/current-connection'), null);
  });
}
