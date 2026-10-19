import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/models.dart';
import 'package:quiet_vpn/core/connection_strategy.dart';
import 'package:quiet_vpn/core/xray_failure.dart';
import 'package:quiet_vpn/data/public_catalog.dart';

void main() {
  test('proven alternative wins; protected candidates get two exploration slots', () {
    final servers = PublicCatalog.parse('ss://aes-128-gcm:secret@a.example:443\n'
      'vless://12345678-1234-1234-1234-123456789abc@b.example:443?security=tls\n'
      'vless://12345678-1234-1234-1234-123456789abc@c.example:443?security=tls\n'
      'ss://aes-128-gcm:secret@d.example:443').servers;
    final selected = ConnectionStrategy.select(servers, limit: 3, priority: (_) => 0);
    expect(selected.map((s) => s.host), ['b.example', 'c.example', 'a.example']);
    final proven = ConnectionStrategy.select(servers, limit: 1,
      priority: (s) => s.host == 'd.example' ? 1 : 0);
    expect(proven.single.host, 'd.example');
    final cooldown = ConnectionStrategy.select(servers, limit: 2,
      priority: (s) => s.host == 'b.example' ? -1 : 0);
    expect(cooldown.any((s) => s.host == 'b.example'), false);
  });
  test('deep queue fills eight slots after zero or one proxy success', () {
    final pool = PublicCatalog.parse([for (var i = 0; i < 12; i++)
      'vless://12345678-1234-1234-1234-123456789abc@node$i.example:443?security=tls'].join('\n')).servers;
    for (final verified in [pool.take(0).toList(), [pool.last]]) {
      final queue = ConnectionStrategy.tunnelQueue(verified, pool,
        deep: true, priority: (_) => 0);
      expect(queue.length, 8);
      expect(queue.map((s) => s.profile).toSet().length, 8);
      if (verified.isNotEmpty) expect(queue.first, pool.last);
    }
    expect(ConnectionStrategy.tunnelQueue([], pool.take(3).toList(),
      deep: true, priority: (_) => 0).length, 3);
    expect(ConnectionStrategy.tunnelQueue([pool.last], pool,
      deep: false, priority: (_) => 0).length, 6);
  });
  test('deep WireGuard fallback keeps eight distinct configurations', () {
    final pool = [for (var i = 0; i < 10; i++) VpnServer(
      id: '$i', name: '$i', country: 'Test', countryCode: 'US',
      host: '192.0.2.${i + 1}', port: 51820, transport: 'udp',
      profile: '# public config\n[Interface]\nPrivateKey = fixture-$i', source: 'same-source')];
    final queue = ConnectionStrategy.tunnelQueue([], [...pool, ...pool],
      deep: true, priority: (_) => 0);
    expect(queue.length, 8);
    expect(queue.map((s) => s.profile).toSet().length, 8);
    expect(ConnectionStrategy.tunnelQueue([], pool,
      deep: false, priority: (_) => 0).length, 6);
  });
  test('Xray reason does not expose log credentials or addresses', () {
    const raw = 'failed to build > invalid "password": SECRET at private.example';
    expect(XrayFailure.explain(raw), 'Некорректный ключ REALITY');
    expect(XrayFailure.explain('unrecognized SECRET'), isNull);
  });
}
