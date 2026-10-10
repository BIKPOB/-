import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/profile_policy.dart';
import 'package:quiet_vpn/core/proxy_profile.dart';
import 'package:quiet_vpn/data/profile_store.dart';
const uuid = '12345678-1234-1234-1234-123456789abc';
void main() {
  test('VLESS REALITY preserves server transport and credentials', () {
    final key=base64Url.encode(List.filled(32,1)).replaceAll('=','');
    final p=ProxyProfile.parse('vless://$uuid@example.com:443?security=reality&type=tcp&sni=example.net&pbk=$key&sid=ab12&flow=xtls-rprx-vision');
    final config=jsonDecode(p.configuration) as Map;
    final outbound=(config['outbounds'] as List).single as Map;
    expect(outbound['protocol'],'vless');
    expect(outbound['streamSettings']['realitySettings']['publicKey'],key);
    expect(outbound['settings']['vnext'][0]['users'][0]['id'],uuid);
    expect(config['log']['loglevel'],'none');
    expect(config['inbounds'][0]['listen'],'127.0.0.1');
  });
  test('Shadowsocks SIP002, plaintext and legacy links normalize identically', () {
    final auth=base64Url.encode(utf8.encode('aes-256-gcm:secret')).replaceAll('=','');
    final legacy=base64Url.encode(utf8.encode('aes-256-gcm:secret@example.com:443')).replaceAll('=','');
    final links=['ss://$auth@example.com:443','ss://aes-256-gcm:secret@example.com:443','ss://$legacy'];
    for(final link in links){
      final p=ProxyProfile.parse(link);
      expect(p.protocol,'shadowsocks');
      expect(p.outbound['settings']['servers'][0]['password'],'secret');
      expect(ProxyProfile.parse(p.uri).configuration,p.configuration);
    }
  });
  test('unsafe or unsupported profile options are rejected, not ignored', () {
    for(final link in ['vless://bad@example.com:443','vless://$uuid@example.com:0',
      'vless://$uuid@example.com:443?allowInsecure=1', 'vless://$uuid@example.com:443?security=unknown',
      'vless://$uuid@example.com:443?type=ws&type=tcp','vless://$uuid@example.com:443?security=reality',
      'ss://none:secret@example.com:443','ss://aes-256-gcm:secret@example.com:443?plugin=exec']) {
      expect(()=>ProxyProfile.parse(link),throwsFormatException,reason:link);
    }
    expect(()=>ProfilePolicy.parse('client\nremote example.com 1194'),throwsFormatException);
  });
  test('migration skips old OpenVPN without losing supported profiles', () {
    final entry={'id':'new','name':'new','country':'Test','countryCode':'--','host':'example.com',
      'port':443,'transport':'tcp','source':'Импорт','profile':'vless://$uuid@example.com:443','protocol':'vless'};
    final old={...entry,'id':'old','protocol':'openvpn','profile':'client\nremote example.com 1194'};
    final loaded=ProfileStore.decodeProfiles(jsonEncode([old,entry]));
    expect(loaded.map((s)=>s.id),['new']);
  });
  test('VLESS transports emit matching Xray settings', () {
    for(final network in ['ws','grpc','xhttp']) {
      final p=ProxyProfile.parse('vless://$uuid@example.com:443?security=tls&type=$network&sni=example.com&path=%2Fvpn&serviceName=grpc');
      expect(p.outbound['streamSettings']['network'],network);
      expect(p.outbound['streamSettings']['${network}Settings'],isNotNull);
    }
  });
}
