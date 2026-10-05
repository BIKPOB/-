import 'package:flutter/services.dart';

class ConfigBrowser {
  static const _channel = MethodChannel('quietvpn/config-browser');
  static Future<String?> open(String source) => _channel.invokeMethod<String>('open', {'source': source});
}
