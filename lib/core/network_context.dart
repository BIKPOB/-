/// A transient snapshot. Android's link estimates are not measured VPN speed.
class NetworkContext {
  const NetworkContext({this.type = 'other', this.session = '', this.historyKey, this.signal, this.linkMbps,
    this.ambiguous = false, this.vpnPresent = false, this.extended = false, this.phoneGranted = false, this.wifiMhz, this.radio, this.mobileSignal, this.operator, this.downKbps, this.upKbps, this.metered, this.roaming, this.validated});
  final String type, session;
  final String? historyKey;
  final bool ambiguous, vpnPresent, extended, phoneGranted;
  final int? wifiMhz, radio, mobileSignal;
  final String? operator;
  String get environmentKey => '$type|${operator ?? "?"}|${radio ?? 0}|${wifiBand ?? 0}${(historyKey ?? session).isEmpty ? '' : '|${historyKey ?? session}'}';
  int? get wifiBand => wifiMhz == null ? null : wifiMhz! >= 5925 ? 6 : wifiMhz! >= 4900 ? 5 : 2;
  String get radioLabel => radio == 20 ? '5G NR' : radio == 13 ? 'LTE' :
    [3, 5, 6, 8, 9, 10, 12, 14, 15].contains(radio) ? '3G' :
    [1, 2, 4, 7, 11, 16].contains(radio) ? '2G' : 'тип связи недоступен';
  final int? signal, downKbps, upKbps, linkMbps;
  final bool? metered, roaming, validated;
  factory NetworkContext.fromMap(Map<dynamic, dynamic> m) => NetworkContext(
    historyKey: m['historyKey'] as String?, extended: m['extended'] == true, phoneGranted: m['phoneGranted'] == true,
    wifiMhz: m['wifiMhz'] as int?, radio: m['radio'] as int?, mobileSignal: m['mobileSignal'] as int?, operator: m['operator'] as String?,
    linkMbps: (m['linkMbps'] as num?)?.toInt(),
    vpnPresent: m['vpnPresent'] == true, ambiguous: m['ambiguous'] == true, type: m['type'] as String? ?? 'other', session: m['session'] as String? ?? '',
    signal: m['signal'] as int?, downKbps: m['downKbps'] as int?, upKbps: m['upKbps'] as int?,
    metered: m['metered'] as bool?, roaming: m['roaming'] as bool?, validated: m['validated'] as bool?);
  bool sameConnection(NetworkContext other) => type == other.type && session == other.session;
  List<double> get features => [
    signal == null ? 0 : ((signal! + 100) / 70).clamp(0, 1).toDouble(), signal == null ? 0 : 1,
    downKbps == null ? 0 : (downKbps! / 100000).clamp(0, 1).toDouble(),
    upKbps == null ? 0 : (upKbps! / 50000).clamp(0, 1).toDouble(),
    metered == null ? 0 : (metered! ? 1 : -1), roaming == null ? 0 : (roaming! ? 1 : -1),
    validated == null ? 0 : (validated! ? 1 : -1),
    wifiBand == null ? 0 : wifiBand! / 6,
    radio == 20 ? 1 : radio == 13 ? .7 : radio == null ? 0 : .3,
    mobileSignal == null ? 0 : (mobileSignal! / 4).clamp(0, 1).toDouble()];
  String get label => ambiguous ? 'Базовая сеть VPN не определена однозначно' : '${type == 'wifi' ? 'Wi-Fi' : type == 'mobile' ? 'Мобильная сеть' : type == 'offline' ? 'Нет сети' : type == 'ethernet' ? 'Ethernet' : 'Другая сеть'}'
    '${type == 'ethernet' && linkMbps != null ? ' · линк $linkMbps Мбит/с (не скорость интернета)' : ''}'
    '${type == 'wifi' && extended ? ' · ${wifiBand == null ? 'диапазон недоступен' : '${wifiBand == 2 ? '2,4' : wifiBand} ГГц'}' : ''}'
    '${type == 'mobile' && extended ? ' · $radioLabel${phoneGranted ? '' : ' (нет разрешения)'}' : ''}'
    '${signal == null ? '' : ' · сигнал $signal'}${metered == true ? ' · лимитный трафик' : ''}${roaming == true ? ' · роуминг' : ''}';
}
