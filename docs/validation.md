# Проверка поставки — 2026-10-02

Android APK 0.2.0 успешно собран в GitHub Actions:
https://github.com/BIKPOB/-/actions/runs/37057875626

Исходный коммит: `1b30e5fb9d1301b001b479dfd9021d9b47f847c3`.

| Проверка | Результат |
|---|---|
| Python catalog tests | 7 passed |
| flutter analyze | No issues found |
| Flutter tests | 10 passed |
| Android release APK | Успешно собран, 29 179 537 байт |
| Подпись APK | apksigner verify успешно; v2, Android Debug |
| Android package | app.quietvpn.quiet_vpn, versionName 0.2.0, versionCode 2 |
| SDK | min 26 (Android 8.0), target 35 |
| Flutter native libraries | ARM32 и ARM64 присутствуют |
| Целостность | ZIP CRC и SHA-256 проверены после скачивания |
| Windows EXE | Не собран |
| Подключение OpenVPN, внешний IP, DNS/IPv6 | Не проверены на устройстве |

SHA-256 APK:
`4ebcd1911882d91ea9bfcfbdac8e1c34c1ed2bb6b0cfbe54d9fd762f19e1a698`

Это тестовая поставка с debug-сертификатом, не production-подпись для магазина.
Перед публикацией нужны постоянный ключ подписи и проверка поддержки устройств
с 16 КБ memory pages.

На Android ещё нужно проверить реальные TCP/UDP профили, VPN permission,
маршруты, внешний IP, DNS/IPv6, смену сети и работу в фоне.
Успешная сборка не подтверждает доступность публичных серверов.
