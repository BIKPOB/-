package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

/** Explicit VPN Network: DNS and HTTPS cannot silently fall back to mobile/Wi-Fi. */
object TunnelProbe {
    private val timer = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var pending: HttpsURLConnection? = null
    @Volatile private var generation = 0
    const val TEST_BYTES = 262144
    const val MIN_BYTES_PER_SECOND = 131072L
    fun acceptable(bytes: Int, millis: Long): Boolean = bytes >= TEST_BYTES &&
        bytes * 1000L / maxOf(1L, millis) >= MIN_BYTES_PER_SECOND
    fun measure(context: Context): Map<String, Any> {
        val token = generation
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        } ?: return mapOf("delay" to -1L, "detail" to "Системный VPN недоступен для проверки")
        val start = SystemClock.elapsedRealtime()
        var phase = "DNS и HTTPS через системный VPN"
        var bytes = 0
        try {
            for ((index, address) in listOf("https://www.gstatic.com/generate_204",
                "https://speed.cloudflare.com/__down?bytes=$TEST_BYTES").withIndex()) {
                check(token == generation)
                val request = network.openConnection(URL(address)) as HttpsURLConnection
                pending = request
                request.connectTimeout = 10000; request.readTimeout = 10000
                request.instanceFollowRedirects = false; request.useCaches = false
                request.setRequestProperty("Accept-Encoding", "identity")
                val deadline = timer.schedule({ request.disconnect() }, 12, TimeUnit.SECONDS)
                try {
                    if (index == 0) {
                        phase = "DNS и HTTPS через системный VPN"
                        check(request.responseCode == 204) { "HTTP status" }
                    } else {
                        phase = "загрузка 256 КиБ через системный VPN"
                        check(request.responseCode == 200) { "HTTP status" }
                        val downloadStart = SystemClock.elapsedRealtime()
                        request.inputStream.use { input ->
                            val buffer = ByteArray(8192)
                            while (bytes < TEST_BYTES) {
                                check(token == generation)
                                val count = input.read(buffer, 0, minOf(buffer.size, TEST_BYTES - bytes))
                                if (count < 0) break
                                bytes += count
                            }
                        }
                        val elapsed = maxOf(1L, SystemClock.elapsedRealtime() - downloadStart)
                        val bps = bytes * 1000L / elapsed
                        check(bytes == TEST_BYTES) { "Incomplete download" }
                        if (!acceptable(bytes, elapsed)) return mapOf("delay" to SystemClock.elapsedRealtime() - start,
                            "quality" to false, "bytesPerSecond" to bps,
                            "detail" to "VPN работает, но тест медленный: ${bps / 1024} КиБ/с. Сохранён как резервный кандидат (цель 128 КиБ/с)")
                        return mapOf("delay" to SystemClock.elapsedRealtime() - start, "bytesPerSecond" to bps, "quality" to true,
                            "detail" to "Системный VPN: DNS, HTTPS и 256 КиБ подтверждены · ${bps / 1024} КиБ/с")
                    }
                } finally { deadline.cancel(false); request.disconnect(); if (pending === request) pending = null }
            }
        } catch (e: Exception) {
            return mapOf("delay" to -1L, "detail" to "$phase: ${ProbeFailure.describe(e)}, $bytes байт")
        }
        return mapOf("delay" to -1L, "detail" to "Системная проверка не завершена")
    }
    fun cancel() { generation++; pending?.disconnect(); pending = null }
}

