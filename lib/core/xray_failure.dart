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
      'unable to set routes': 'Не удалось настроить маршруты TUN',
      'unable to set ips': 'Не удалось назначить адреса TUN',
      'unable to set metric and mtu': 'Не удалось настроить метрику или MTU TUN',
      'unable to set dns': 'Не удалось назначить DNS TUN',
      'fwpmengineopen0 failed': 'Windows Filtering Platform: не удалось открыть сессию фильтрации',
      'fwpmfilteradd0 failed': 'Windows Filtering Platform: не удалось добавить защитный фильтр',
      'unable to block': 'Не удалось включить защиту от утечек вне TUN',
      'failed to start tun': 'Не удалось запустить TUN-интерфейс',
      'cannot create a file when that file already exists': 'VPN-адаптер или ресурс уже существует',
      'the device is not ready': 'VPN-адаптер ещё не готов',
      'forwarding is on': 'Пересылка пакетов или мобильная точка доступа создаёт петлю маршрутизации',
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
