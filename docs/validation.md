# Проверка поставки — 2026-09-19

| Проверка | Фактический результат |
|---|---|
| Python catalog tests | **7 passed**; включая локальный HTTP-сервер, TTL и восстановление кэша |
| Синтаксис Dart | **14 файлов**, tree-sitter-dart: 0 syntax errors |
| Android manifest | XML parse выполнен |
| pubspec / Compose / CI | YAML parse выполнен |
| Python-файлы | compile() выполнен без ошибок |
| Flutter analyzer / Flutter tests | **Не запускались**: Flutter/Dart SDK не установлены |
| Dart-тесты в проекте | Написаны 10 тестов, результат выполнения не подтверждён |
| APK / Windows EXE | **Не собраны** |
| Docker build / TLS deploy | **Не запускались** |
| VPN Gate live feed из контейнера | HTTPS-загрузка завершилась Proxy CONNECT timeout |
| Подключение OpenVPN и внешний IP | **Не проверены** на Windows/Android |

Синтаксический разбор не проверяет Dart-типы, разрешение пакетов, API плагинов,
Gradle/NDK, Windows-драйверы или поведение OS VPN. Он не заменяет flutter analyze,
flutter test и нативную сборку.

Официальные страницы VPN Gate, VPNBook, VPN Jantit, Flutter и плагинов прочитаны
через веб-поиск. Наличие страницы с каталогом не считается успешной загрузкой
профиля из приложения или успешным VPN-подключением.

Загрузка Dart SDK для более глубокой локальной проверки также завершилась Proxy
CONNECT timeout. Установленные только для синтаксической проверки Python-пакеты
не включены в пользовательский архив.

## Написанные Flutter-тесты

`test/core_test.dart`: запрет скриптов/внешних файлов; inline-блоки; TLS-role и
маршрут по умолчанию; native management state; CSV; private IP; параллелизм;
честный статус UDP без TCP latency.

`test/view_model_test.dart`: повторное подключение во время native start;
сериализация cleanup при native error, пришедшей во время запуска.

## Что нужно для подтверждения готовой сборки

1. Запустить tools/bootstrap.py на установленном Flutter 3.32.8.
2. Выполнить flutter analyze и flutter test; устранить возможные несовместимости
   плагинов/SDK, которые не выявляются синтаксическим разбором.
3. Собрать Android APK и Windows приложение на соответствующих toolchains.
4. Проверить реальные TCP/UDP OpenVPN-профили, сертификаты, permission, маршруты,
   внешний IP, DNS/IPv6, смену сети и поведение в фоне.

В проект не включены фиктивные «работающие серверы». Адреса 8.8.8.8/1.1.1.1
используются только как синтетические данные парсерных тестов, не как VPN-реле.
