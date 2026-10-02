import 'models.dart';

EngineEvent? parseManagementState(String line) {
  if (line.startsWith('>FATAL:') || line.startsWith(">PASSWORD:Verification Failed")) {
    return const EngineEvent(ConnectionState.error, 'OpenVPN сообщил об ошибке подключения');
  }
  if (!line.startsWith('>STATE:')) return null;
  final fields = line.substring(7).split(',');
  if (fields.length < 3) return null;
  return switch (fields[1]) {
    'CONNECTED' => fields[2] == 'SUCCESS' ? const EngineEvent(ConnectionState.connected) : null,
    'EXITING' => const EngineEvent(ConnectionState.disconnected),
    'CONNECTING' || 'WAIT' || 'AUTH' || 'GET_CONFIG' || 'ASSIGN_IP' ||
      'ADD_ROUTES' || 'RECONNECTING' || 'RESOLVE' || 'TCP_CONNECT' => const EngineEvent(ConnectionState.connecting),
    _ => null,
  };
}

String managementQuote(String value) {
  if (value.contains('\n') || value.contains('\r') || value.contains('\u0000')) {
    throw const FormatException('Перевод строки в учётных данных');
  }
  return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}
