import 'dart:io';
import 'package:quiet_vpn/core/search_rotation.dart';
void check(bool value, String message) { if (!value) throw StateError(message); }
void main() {
  final data = <String,dynamic>{};
  var rotation = SearchRotation(data);
  final now = DateTime.utc(2026,10,18);
  final pool = List.generate(100, (i) => '$i');
  List<String> order(String network, [DateTime? time]) => rotation.order(pool, network, (s)=>s, time??now);
  rotation.mark('wifi', order('wifi').take(24), now);
  check(order('wifi').first=='24', 'Candidates beyond old shortlist must advance');
  check(order('lte').first=='0', 'Networks must remain independent');
  final restored = Map<String,dynamic>.from(data);
  rotation = SearchRotation(restored);
  check(order('wifi').first=='24', 'Restart must preserve progress');
  rotation.mark('wifi', ['24','25','26'], now.add(const Duration(seconds:1)));
  check(order('wifi',now.add(const Duration(seconds:2))).first=='27', 'Only attempted groups advance');
  final refreshed = rotation.order(['0','new','27'], 'wifi', (s)=>s, now.add(const Duration(seconds:2)));
  check(refreshed.join(',')=='new,27,0', 'Refresh must preserve history and admit new profiles');
  check(order('wifi',now.add(const Duration(days:8))).first=='0', 'History must expire');
  for(var i=0;i<10;i++) {rotation.mark('network$i',['x'],now);}
  check(restored.length<=8, 'Storage must be bounded');
  stdout.writeln('Search rotation: shortlist progression, network isolation, restart, partial attempts, refresh, expiry passed.');
}
