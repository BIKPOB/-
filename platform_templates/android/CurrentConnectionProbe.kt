package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.HttpURLConnection
import java.util.concurrent.atomic.AtomicBoolean

/** Uses the app's current default network, never BaseNetwork or VPN protect(). */
class CurrentConnectionProbe(private val context: Context) {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var connection: HttpURLConnection? = null
    fun cancel() { cancelled.set(true); connection?.disconnect() }
    fun run(label: String): String {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val network = cm.activeNetwork ?: return "Нет текущей сети."
        val caps = cm.getNetworkCapabilities(network)
        val vpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        val started = android.os.SystemClock.elapsedRealtime()
        val report = StringBuilder("Quiet VPN · 0.10.11 · отчёт текущего соединения v1\n")
        report.append("Время: ${java.time.Instant.now()}\nМетка пользователя: $label\n")
        report.append("Android ${android.os.Build.VERSION.RELEASE} / API ${android.os.Build.VERSION.SDK_INT}\n")
        report.append("VPN в маршруте приложения по данным Android: $vpn\n")
        report.append("Лимитная сеть: ${cm.isActiveNetworkMetered}\n")
        report.append("Метка не подтверждает название VPN. Исключения Turbo могут направлять Quiet напрямую.\n")
        fun ensureRoute() {
            check(!cancelled.get()) { "Cancelled" }
            check(cm.activeNetwork == network) { "NetworkChanged" }
            check(android.os.SystemClock.elapsedRealtime() - started < 75000) { "Deadline" }
        }
        fun get(url: String, limit: Int, exact: Boolean = false): Pair<ByteArray, Long> {
            ensureRoute()
            val c = network.openConnection(java.net.URL(url)) as HttpURLConnection
            connection = c
            c.connectTimeout = 6000; c.readTimeout = 6000
            c.instanceFollowRedirects = false; c.useCaches = false
            c.setRequestProperty("Accept-Encoding", "identity")
            val t = android.os.SystemClock.elapsedRealtime()
            try {
                check(c.responseCode in listOf(200, 204)) { "HTTP${c.responseCode}" }
                val out = java.io.ByteArrayOutputStream()
                c.inputStream.use { input ->
                    val buffer = ByteArray(8192)
                    while (out.size() < limit) {
                        ensureRoute()
                        val n = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
                        if (n < 0) break
                        out.write(buffer, 0, n)
                    }
                }
                ensureRoute()
                if (exact) check(out.size() == limit) { "Incomplete" }
                return out.toByteArray() to maxOf(1L, android.os.SystemClock.elapsedRealtime() - t)
            } finally { c.disconnect(); connection = null }
        }
        val latency = mutableListOf<Long>()
        val targets = listOf("https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204", "https://ya.ru/")
        for (url in targets) {
            try {
                val (_, ms) = get(url, 4096)
                latency.add(ms); report.append("HTTPS $url: $ms мс\n")
            } catch (e: Exception) { report.append("HTTPS $url: ${e.javaClass.simpleName}\n") }
        }
        report.append("HTTPS успешно: ${latency.size}/${targets.size}; это не измерение потерь пакетов.\n")
        if (latency.size > 1) report.append("Разброс HTTPS между узлами: ${latency.maxOrNull()!! - latency.minOrNull()!!} мс (не ping).\n")
        try {
            val (data, _) = get("https://www.cloudflare.com/cdn-cgi/trace", 4096)
            val ip = data.toString(Charsets.UTF_8).lineSequence().firstOrNull { it.startsWith("ip=") }?.removePrefix("ip=")
            report.append("Выходной IP по Cloudflare: ${ip?.takeIf { it.matches(Regex("[0-9a-fA-F:.]{3,45}")) } ?: "не определён"}\n")
        } catch (e: Exception) { report.append("Выходной IP: ${e.javaClass.simpleName}\n") }
        val speeds = mutableListOf<Double>()
        repeat(3) { i ->
            try {
                val (data, ms) = get("https://speed.cloudflare.com/__down?bytes=1048576&quiet=${System.nanoTime()}", 1048576, true)
                val speed = data.size * 8.0 / ms / 1000
                speeds.add(speed)
                report.append("Загрузка ${i + 1}/3: ${String.format(java.util.Locale.US, "%.2f", speed)} Мбит/с\n")
            } catch (e: Exception) { report.append("Загрузка ${i + 1}/3: ${e.javaClass.simpleName}\n") }
        }
        report.append("Успешных загрузок: ${speeds.size}/3. Короткий тест 1 МиБ до Cloudflare, включая установление соединения; не предел скорости канала. Выгрузка не измеряется.\n")
        report.append("Сеть в конце: ${if (cm.activeNetwork == network) "та же" else "ИЗМЕНИЛАСЬ — сравнение недостоверно"}\n")
        report.append("${if (cancelled.get()) "ОТМЕНЕНО: неполный отчёт.\n" else ""}Протокол и ключи чужого VPN не определяются. IP включён в отправляемый отчёт.\n")
        return report.toString()
    }
}
