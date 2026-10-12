/// A transient snapshot. Android's link estimates are not measured VPN speed.
class NetworkContext {
  const NetworkContext({this.type = 'other', this.session = '', this.signal,
    this.ambiguous = false, this.downKbps, this.upKbps, this.metered, this.roaming, this.validated});
  final String type, session;
  final bool ambiguous;
  final int? signal, downKbps, upKbps;
  final bool? metered, roaming, validated;
  factory NetworkContext.fromMap(Map<dynamic, dynamic> m) => NetworkContext(
    ambiguous: m['ambiguous'] == true, type: m['type'] as String? ?? 'other', session: m['session'] as String? ?? '',
    signal: m['signal'] as int?, downKbps: m['downKbps'] as int?, upKbps: m['upKbps'] as int?,
    metered: m['metered'] as bool?, roaming: m['roaming'] as bool?, validated: m['validated'] as bool?);
  bool sameConnection(NetworkContext other) => type == other.type && session == other.session;
  List<double> get features => [
    signal == null ? 0 : ((signal! + 100) / 70).clamp(0, 1).toDouble(), signal == null ? 0 : 1,
    downKbps == null ? 0 : (downKbps! / 100000).clamp(0, 1).toDouble(),
    upKbps == null ? 0 : (upKbps! / 50000).clamp(0, 1).toDouble(),
    metered == null ? 0 : (metered! ? 1 : -1), roaming == null ? 0 : (roaming! ? 1 : -1),
    validated == null ? 0 : (validated! ? 1 : -1)];
  String get label => ambiguous ? 'Базовая сеть VPN не определена однозначно' : '${type == 'wifi' ? 'Wi-Fi' : type == 'mobile' ? 'Мобильная сеть' : type == 'offline' ? 'Нет сети' : 'Другая сеть'}'
    '${signal == null ? '' : ' · сигнал $signal'}${metered == true ? ' · лимитный трафик' : ''}${roaming == true ? ' · роуминг' : ''}';
}
