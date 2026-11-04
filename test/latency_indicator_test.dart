import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/ui/latency_indicator.dart';

void main() {
  testWidgets('only fresh authenticated HTTPS has latency colors', (tester) async {
    for (final entry in {100:Colors.green,101:Colors.yellow,250:Colors.yellow,251:Colors.red}.entries) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body:LatencyIndicator(
        HealthResult(Reachability.reachable,entry.key,'HTTPS через сервер',DateTime.now())))));
      expect(tester.widget<Icon>(find.byType(Icon)).color,entry.value);
      expect(find.text('HTTPS · ${entry.key} мс'),findsOneWidget);
    }
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:LatencyIndicator(
      HealthResult(Reachability.reachable,50,'HTTPS через сервер',DateTime.now().subtract(const Duration(minutes:16)))))));
    expect(tester.widget<Icon>(find.byType(Icon)).color,Colors.grey);
    expect(find.text('Проверка устарела'),findsOneWidget);
  });
  testWidgets('endpoint latency is not displayed as VPN quality', (tester) async {
    for (final entry in {0: Colors.green, 100: Colors.green, 101: Colors.yellow,
      250: Colors.yellow, 251: Colors.red, 1000: Colors.red}.entries) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        LatencyIndicator(HealthResult(Reachability.reachable, entry.key)))));
      expect(tester.widget<Icon>(find.byType(Icon)).color, Colors.grey);
      expect(find.text('${entry.key} мс'), findsNothing);
      expect(find.text('Адрес отвечает · VPN не проверен'), findsOneWidget);
    }
    for (final state in [Reachability.unknown, Reachability.unreachable, Reachability.notMeasured]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: LatencyIndicator(HealthResult(state)))));
      expect(tester.widget<Icon>(find.byType(Icon)).color, Colors.grey);
      expect(find.text('0 мс'), findsNothing);
    }
  });
}
