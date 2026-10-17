import 'dart:convert';
import 'dart:io';
import 'package:quiet_vpn/platform/windows_config.dart';

Future<void> main(List<String> args) async {
  const base = 'vless://12345678-1234-1234-1234-123456789abc@example.com:443';
  final key = base64Url.encode(List.generate(32, (i) => i + 1)).replaceAll('=', '');
  final profiles = [
    '$base?security=tls&type=tcp',
    '$base?security=tls&type=ws&path=%2Ftest',
    '$base?security=tls&type=grpc&serviceName=test',
    '$base?security=tls&type=xhttp&path=%2Ftest',
    '$base?security=reality&type=tcp&sni=example.com&pbk=$key&sid=ab&flow=xtls-rprx-vision',
    'ss://aes-128-gcm:fixture-secret@example.com:443',
  ];
  for (var i = 0; i < profiles.length; i++) {
    final p = await Process.start(args.single, ['run', '-test', '-config', 'stdin:']);
    final out = p.stdout.drain<void>();
    final err = p.stderr.drain<void>();
    p.stdin.write(jsonEncode(WindowsConfig.xray(profiles[i], '203.0.113.1')));
    await p.stdin.close();
    final code = await p.exitCode;
    await Future.wait([out, err]);
    if (code != 0) throw StateError('Generated configuration $i rejected by pinned Xray: $code');
  }
  try {
    WindowsConfig.xray(base, '203.0.113.1');
    throw StateError('Unprotected public VLESS accepted');
  } on FormatException { /* Unsupported profile is rejected before TUN startup. */ }
  stdout.writeln('Six generated configurations accepted by pinned Xray; unprotected VLESS rejected.');
}
