import 'package:flutter/material.dart';
import '../core/models.dart';

class LatencyIndicator extends StatelessWidget {
  const LatencyIndicator(this.result, {super.key});
  final HealthResult? result;

  @override
  Widget build(BuildContext context) {
    final ms = result?.milliseconds;
    final measured = result?.state == Reachability.reachable && ms != null && ms >= 0;
    final color = measured
      ? ms <= 100 ? Colors.green : ms <= 250 ? Colors.yellow : Colors.red
      : Colors.grey;
    final label = measured ? '${result!.method.isEmpty ? '' : '${result!.method} · '}$ms мс' : switch (result?.state) {
      Reachability.unreachable => 'Нет ответа ICMP/TCP',
      Reachability.notMeasured => 'Пинг недоступен',
      Reachability.paused => 'Пауза',
      _ => 'Не проверен',
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 10, color: color),
      const SizedBox(width: 6),
      Text(label),
    ]);
  }
}
