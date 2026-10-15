import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/network_context.dart';
import 'package:quiet_vpn/core/adaptive_selector.dart';

void main() {
  test('Ethernet link rate is labelled separately and never used as measured speed', () {
    final network = NetworkContext.fromMap({'type': 'ethernet', 'session': 'same', 'linkMbps': 1000});
    expect(network.label, contains('не скорость интернета'));
    expect(network.linkMbps, 1000);
    expect(network.downKbps, isNull);
    expect(network.features, const NetworkContext(type: 'ethernet').features);
    expect(network.sameConnection(const NetworkContext(type: 'ethernet', session: 'same')), true);
  });
  test('signal fluctuation keeps session, changing Wi-Fi cancels session', () {
    const a = NetworkContext(type: 'wifi', session: '1', signal: -60);
    expect(a.sameConnection(const NetworkContext(type: 'wifi', session: '1', signal: -85)), isTrue);
    expect(a.sameConnection(const NetworkContext(type: 'wifi', session: '2')), isFalse);
  });
  test('missing and weak signal are distinct and features remain bounded', () {
    const missing = NetworkContext();
    const weak = NetworkContext(signal: -120, downKbps: 10000000, upKbps: -1);
    expect(missing.features[1], 0);
    expect(weak.features[1], 1);
    expect(weak.features.every((v) => v.isFinite && v >= -1 && v <= 1), isTrue);
  });
  test('old binary labels are not imported into the measured-quality model', () {
    final old = {'hidden': List.generate(6, (_) => List.filled(9, .1)),
      'output': List.filled(7, .2), 'history': <String, dynamic>{}, 'samples': 3};
    final fresh = AdaptiveSelector.decode(jsonEncode(old));
    expect(fresh.samples, 0);
    expect(fresh.hidden.first.length, 19);
  });
  test('radio and band distinguish environments, missing data is explicit', () {
    final wifi = NetworkContext.fromMap({'type': 'wifi', 'extended': true, 'wifiMhz': 5180});
    expect(wifi.wifiBand, 5);
    expect(wifi.features.length, 10);
    expect(wifi.environmentKey, isNot(const NetworkContext(type: 'wifi', wifiMhz: 2412).environmentKey));
    expect(const NetworkContext(type: 'mobile', extended: true).label, contains('нет разрешения'));
    expect(const NetworkContext(type: 'mobile', radio: 13).radioLabel, 'LTE');
  });
}
