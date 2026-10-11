# Публичный каталог 0.7.1

«Добавить сервер → Публичные серверы VLESS / Shadowsocks» загружает список без пользовательской ссылки. После выбора и сохранения сервер подключается обычной кнопкой на главном экране.

Источник: https://github.com/Au1rxx/free-vpn-subscriptions (MIT). Используется опубликованный output/v2ray-base64.txt. Резервный снимок от 2026-10-10 включён в APK; его дата явно показывается при недоступности источника. Заявленные авторами проверки не считаются подтверждением доступности в сети пользователя. Профили сторонних владельцев могут перестать работать; гарантии скорости или доверия к оператору отсутствуют.

Загружаются только конфигурационные ссылки, не исполняемые компоненты. При загрузке: HTTPS, тайм-аут 12 секунд, лимит 2 МиБ, строгий существующий парсер, отбрасывание неизвестных протоколов/параметров и локальных литеральных IP, дедупликация, максимум 100 совместимых профилей на протокол. DNS-имена могут менять адреса; это не полноценная защита от DNS rebinding. Неизвестные названия из подписки не показываются, используется адрес узла. Список обновляется при открытии и вручную. Уже импортированные профили автоматически не заменяются.

Пинг всех элементов запускается по кнопке. Это ICMP/TCP-доступность, не тест туннеля. Подтверждение подключения VLESS/SS остаётся HTTPS-запросом через активный SOCKS. Испытание на телефоне Samsung SM-A256E не проводилось.

Исправлена диагностика: вместо зафиксированной строки 0.6.0 выводится версия установленного пакета.

## 0.7.4: WireGuard без браузера

Добавлен независимый источник https://github.com/NiREvil/vless/blob/main/sub/v2rayng-wg.txt и резервный снимок 2026-10-11. Лицензия источника включена в assets/WIREGUARD_SOURCE_LICENSE.txt. Список загружается параллельно с VLESS/Shadowsocks, неудача одного источника не удаляет другой. Сервер сохраняется по кнопке «Добавить» с названием своего источника.

Поддерживаются ссылки wireguard:// с private key, publickey, address, optional presharedkey, mtu, keepalive, dns. reserved разрешён только 0,0,0: профили, требующие нестандартных ненулевых байтов, не преобразуются с потерей параметров. Ключи/CIDR/Endpoint дополнительно проверяет существующий строгий парсер .conf. Ссылки с маркировкой Proton исключаются. Это сторонние публичные конфигурации с непроверенным сроком действия и доступностью, не автоматически выданные каждому пользователю ключи VPNBook. Общие ключи могут мешать одновременным подключениям.

Профили VPNBook индивидуальны и ограничены по сроку; в эту базу они не копируются. Браузер для загрузки каталога не используется. Смена способа импорта сама по себе не исправляет сетевые тайм-ауты.


## 0.7.5: Xray connection diagnostics

The SOCKS success reply is local acceptance, not confirmation that an outbound
VLESS/Shadowsocks connection completed. Stage text now says this explicitly.
Each verified HTTPS probe has a 20-second wall deadline (18-second read timeout),
with two endpoints and a 45-second channel deadline. The proxy startup watchdog
is 75 seconds, avoiding cancellation before both probes finish. TLS certificate
verification remains enabled. A failed pair still disconnects; unverified tunnels
are not advertised as working.

Xray INFO logs (outbound failures use this level) go to a private, non-backed-up per-session file; access logs
remain disabled. The file is reset for each connection and checked once per
second, truncating above 256 KiB during the session. Reports read at most the
last 64 KiB and export only fixed error categories, never raw log text, addresses,
keys, UUIDs, passwords, or request paths. Unknown errors are explicitly marked
as unclassified. Native tests cover nested transport errors and secret exclusion.

This corrects the premature health-check deadline and the diagnostic blind spot.
It does not prove a public server works in the user's network or establish that
a timeout was caused by filtering, stale credentials, or a specific transport.
