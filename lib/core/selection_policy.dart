import 'dart:convert';
import 'dart:io';

/// Data-only rules. Remote values cannot add targets, keys or routing commands.
class SelectionPolicy {
  const SelectionPolicy({this.version=1,this.fastCandidates=12,this.deepCandidates=24,
    this.fastSeconds=45,this.deepSeconds=100});
  final int version,fastCandidates,deepCandidates,fastSeconds,deepSeconds;
  static SelectionPolicy parse(String text) {
    final m=jsonDecode(text) as Map;
    int bounded(String k,int low,int high) {
      final v=m[k];if(v is! int || v<low || v>high) throw const FormatException('Policy range');return v;
    }
    if(m['schema']!=1 || m['region']!='RU') throw const FormatException('Policy schema');
    return SelectionPolicy(version:bounded('version',1,1000000),fastCandidates:bounded('fastCandidates',3,12),
      deepCandidates:bounded('deepCandidates',3,24),fastSeconds:bounded('fastSeconds',20,60),deepSeconds:bounded('deepSeconds',30,120));
  }
  static Future<String> fetch() async {
    final c=HttpClient()..connectionTimeout=const Duration(seconds:3);
    try {
      return await (() async {
        final r=await c.getUrl(Uri.parse('https://raw.githubusercontent.com/BIKPOB/-/main/assets/connection-policy.json'));
        r.followRedirects=false;final response=await r.close();
        if(response.statusCode!=200) throw const HttpException('Policy HTTP');
        final bytes=<int>[];
        await for(final b in response) {bytes.addAll(b);if(bytes.length>4096) throw const FormatException('Policy too large');}
        final text=utf8.decode(bytes);parse(text);return text;
      })().timeout(const Duration(seconds:4));
    } finally {c.close(force:true);}
  }
}
