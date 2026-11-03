/// Fixed phrases only: never exports remote addresses, credentials or raw logs.
class XrayFailure {
  static String? explain(String text) {
    final lower = text.toLowerCase();
    const reasons = {
      'vless without tls': 'VLESS без TLS/REALITY отклонён движком',
      'unknown "fingerprint"': 'Движок не поддерживает TLS fingerprint профиля',
      'invalid "fingerprint"': 'Некорректный TLS fingerprint профиля',
      'invalid "password"': 'Некорректный ключ REALITY',
      'empty "password"': 'Отсутствует ключ REALITY',
      'invalid "shortid"': 'Некорректный short ID REALITY',
      'invalid "spiderx"': 'Некорректный путь REALITY',
      'address already in use': 'Локальный порт уже занят',
      'access is denied': 'Windows отказала в доступе',
      'failed to create adapter': 'Не удалось создать VPN-адаптер',
      'failed to build': 'Конфигурация не принята движком',
      'failed to load': 'Конфигурация не загружена',
    };
    for (final entry in reasons.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return null;
  }
}
