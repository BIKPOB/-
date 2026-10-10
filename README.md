# Quiet VPN 0.7.0 — Android

Flutter MVVM клиент для WireGuard, VLESS и Shadowsocks. Android 8+;
APK для arm64-v8a и armeabi-v7a. OpenVPN, его нативная библиотека,
установщик, каталог VPN Gate и автоматическое обновление этого каталога удалены.
Windows-сборка старого OpenVPN-клиента больше не выпускается.

## Добавление сервера

«Добавить сервер» → WireGuard / VLESS / Shadowsocks →
- **Браузер**: настоящий Android WebView, вход на сайт, выбор региона, кнопки
  назад/обновить, очистка данных сайта. Открытие HTTPS-сайта своего провайдера.
  VPNBook доступен как источник WireGuard, доступность определяет провайдер.
- **Ключ / файл**: вставка из буфера по нажатию, импорт .conf или .txt.
- **Параметры**: форма с адресом, портом и настройками выбранного протокола.

Браузер перехватывает нажатия на vless:// и ss://, скачивания .conf,
blob/data downloads. «Импорт со страницы» ищет ключи в ссылках и полях формы;
если сайт использует QR или закрытый iframe, скопируйте ключ и нажмите
«Ключ из буфера». Профиль проверяется и сохраняется только после подтверждения.
TLS-ошибки не игнорируются, file/content URL и native JavaScript interface запрещены.
Секреты не выводятся в списке выбора профиля и не публикуются на GitHub.

VLESS: TCP, WebSocket, gRPC, XHTTP; TLS и REALITY; Vision поверх TCP.
При импорте неподдерживаемые параметры отклоняются, а не молча теряются.
Shadowsocks: AEAD AES-GCM/ChaCha20, методы 2022; SIP002 и legacy ss://.
Внешние плагины Shadowsocks не исполняются. Произвольный Xray JSON не импортируется.
WireGuard: один peer, полный маршрут; совместимые дополнительные поля AmneziaWG
сохраняются движком, отдельной карточки AmneziaWG нет.

## Движки и проверка

WireGuard — официальный AmneziaWG Android tunnel, закреплённый коммит
`ff15093bf3856fea0947923474870b86efb682f0`, собирается из исходников.
VLESS/Shadowsocks — flutter_v2ray_client 3.5.0, git-коммит
`c296aad34eeed7d65119a310c79fc64ebf58251b`:
https://github.com/amir-zr/flutter_v2ray_client/tree/c296aad34eeed7d65119a310c79fc64ebf58251b
Этот upstream содержит готовый libv2ray.aar (Xray/AndroidLibXrayLite).
Он не заявляется как собранный нами из исходников; происхождение закреплено git SHA.

Xray запускается в Android VpnService с native TUN. Получение CONNECTED от ядра
само по себе недостаточно: выполняется запрос измерения через активный Xray.
При ошибке этого запроса подключение не объявляется успешным.
Этот контрольный адрес тоже может быть заблокирован; отказ не доказывает DPI.
Само приложение исключено upstream из Xray TUN, поэтому обычный Dart HTTPS
не используется как доказательство работы прокси.

Пинг всех сохранённых серверов запускается одновременно. ICMP, TCP fallback и
отсутствие ответа показываются отдельно. Пинг не подтверждает VPN-handshake.
Отображается скорость загрузки/отдачи активного туннеля.

## Миграция

Старый публичный кэш OpenVPN удаляется. OpenVPN-импорты пропускаются при чтении;
WireGuard-профили сохраняются. Новые импорты хранятся через flutter_secure_storage.
Proton отсутствует. Нет встроенной базы бесплатных VLESS/Shadowsocks серверов:
для подключения нужен действующий профиль от владельца сервера.

## Сборка

Flutter 3.32.8, JDK 17, Android SDK 36, NDK 27.

```sh
python tools/bootstrap.py --platforms android
python tools/build_awg.py
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64,android-arm
python tools/test_native.py
```

GitHub Actions проверяет Flutter и нативные тесты, подпись, состав APK,
отсутствие OpenVPN-библиотек, наличие обоих движков и антивирусный отчёт.
Артефакты сохраняются в Actions. Подпись пока тестовая Android Debug.
Реальные подключения на Samsung, маршруты, DNS/IPv6-утечки и работа при DPI
ещё требуют испытаний; успешный CI их не подтверждает.

Исторические документы в docs относятся к предыдущим версиям и не описывают 0.7.0.
