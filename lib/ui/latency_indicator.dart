import 'package:flutter/material.dart';
import '../core/models.dart';

class LatencyIndicator extends StatelessWidget {
  const LatencyIndicator(this.result, {super.key});
  final HealthResult? result;

  @override
  Widget build(BuildContext context) {
    // Endpoint reachability is not tunnel quality or throughput.
    const color = Colors.grey;
    final label = switch (result?.state) {
      Reachability.reachable => 'Адрес отвечает · VPN не проверен',
      Reachability.unreachable => 'Нет ответа · VPN не проверен',
      Reachability.paused => 'Проверка приостановлена',
      _ => 'VPN не проверен',
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 10, color: color),
      const SizedBox(width: 6),
      Text(label),
    ]);
  }
}
