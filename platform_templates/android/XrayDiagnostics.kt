package app.quietvpn.quiet_vpn

import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Private session diagnostics. Export only fixed categories, never raw Xray text. */
object XrayDiagnostics {
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private var limiter: ScheduledFuture<*>? = null
    private fun file(context: Context) = File(context.noBackupFilesDir, "xray-session.log")
    @Synchronized fun prepare(context: Context): String {
        limiter?.cancel(false)
        val log = file(context)
        log.parentFile?.mkdirs()
        log.writeText("")
        limiter = timer.scheduleAtFixedRate({
            try { if (log.length() > 262144) RandomAccessFile(log, "rw").use { it.setLength(0) } }
            catch (_: Exception) { }
        }, 1, 1, TimeUnit.SECONDS)
        return log.absolutePath
    }
    @Synchronized fun stop() { limiter?.cancel(false); limiter = null }
    fun classify(text: String): String {
        val rules = listOf(
            "connection refused" to "TCP: сервер отказал в соединении",
            "network is unreachable" to "Сеть: маршрут недоступен",
            "no route to host" to "Сеть: нет маршрута к серверу",
            "no such host" to "DNS: имя сервера не найдено",
            "failed to resolve ip" to "DNS: ошибка разрешения адреса сервера",
            "failed to lookup" to "DNS: ошибка разрешения имени",
            "i/o timeout" to "Сеть: истекло ожидание ввода/вывода",
            "context deadline exceeded" to "Xray: истёк срок ожидания операции",
            "connection reset" to "TCP: соединение сброшено",
            "websocket: bad handshake" to "WebSocket: сервер отклонил согласование",
            "failed to dial websocket" to "WebSocket: не удалось установить транспорт",
            "certificate" to "TLS: ошибка сертификата",
            "tls: handshake failure" to "TLS: сервер отклонил согласование",
            "reality" to "REALITY: ошибка соединения или проверки сервера",
            "invalid user" to "Авторизация: сервер отклонил пользователя",
            "invalid response" to "Протокол: некорректный ответ сервера",
            "failed to read response header" to "Протокол: не получен заголовок ответа",
            "failed to find an available destination" to "Xray: не удалось подключиться к назначению",
            "eof" to "Соединение закрыто до завершения обмена"
        )
        // Xray reports outbound failures at INFO, so filter error-bearing lines
        // before classifying. A routine REALITY connection is not an error.
        val lower = text.lowercase(java.util.Locale.ROOT).lineSequence().filter { line ->
            listOf("failed", "error", "timeout", "deadline", "refused", "unreachable",
                "no route", "no such host", "reset", "invalid", "eof", "bad handshake").any { line.contains(it) }
        }.joinToString("\n")
        val matches = rules.filter { lower.contains(it.first) }.map { it.second }.distinct()
        return if (matches.isNotEmpty()) matches.joinToString("; ") else if (lower.isBlank())
            "Xray: ошибки не записаны (это не подтверждает доступность сервера)"
        else "Xray: есть неклассифицированная ошибка; исходный текст скрыт для защиты реквизитов"
    }
    fun report(context: Context): String = try {
        val log = file(context)
        if (!log.exists()) "Xray: диагностическая сессия ещё не запускалась" else {
            val bytes = RandomAccessFile(log, "r").use {
                val length = minOf(it.length(), 65536L).toInt()
                it.seek(it.length() - length)
                ByteArray(length).also { bytes -> it.readFully(bytes) }
            }
            val core = dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager::class.java
            val protected = try { core.getField("quietProtectOk").getLong(null) } catch (_: Exception) { -1L }
            val failed = try { core.getField("quietProtectFailed").getLong(null) } catch (_: Exception) { -1L }
            "Журнал Xray: ${log.length()} байт; защита сокетов: $protected успешных, $failed отказов\n" +
                if (bytes.isEmpty()) "Xray: файл журнала пуст — работа записи не подтверждена"
                else classify(bytes.toString(Charsets.UTF_8))
        }
    } catch (_: Exception) { "Xray: журнал недоступен" }
}
