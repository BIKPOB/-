import 'package:flutter/material.dart';
import '../core/models.dart';

class LatencyIndicator extends StatelessWidget {
  const LatencyIndicator(this.result, {super.key});
  final HealthResult? result;

  @override
  Widget build(BuildContext context) {
    // Endpoint reachability is not tunnel quality or throughput.
    final verified = result?.protocolVerified == true;
    final ms = result?.milliseconds;
    final color = verified && ms != null ? (ms <= 100 ? Colors.green : ms <= 250 ? Colors.yellow : Colors.red) : Colors.grey;
    final label = verified ? 'HTTPS · $ms мс' : (result?.method == 'HTTPS через сервер' || result?.method == 'HTTPS через VPN') ? 'Проверка устарела' : result?.method.startsWith('WireGuard:') == true ? 'Нужна проверка туннеля' : switch (result?.state) {
      Reachability.reachable => 'Адрес отвечает · VPN не проверен',
      Reachability.unreachable => result?.checkedAt != null ? 'HTTPS не подтверждён' : 'Нет ответа · VPN не проверен',
      Reachability.paused => 'Проверка приостановлена',
      _ => 'VPN не проверен',
    };
    return Tooltip(message: '${result?.method ?? 'Не проверен'}${ms == null ? '' : '\nПоследний замер: $ms мс'}${result?.checkedAt == null ? '' : '\nПроверено: ${result!.checkedAt!.toLocal()}'}', child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 10, color: color),
      const SizedBox(width: 6),
      Text(label),
    ]));
  }
}
