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
    fun measure(context: Context, quick: Boolean = false): Map<String, Any> {
        val token = generation
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        } ?: return mapOf("delay" to -1L, "detail" to "Системный VPN недоступен для проверки")
        val start = SystemClock.elapsedRealtime()
        if (quick) {
            // Confirm real system VPN routing, not the app-local Xray SOCKS
            // listener. Fall back to a second HTTPS 204 endpoint if needed.
            val failures = mutableListOf<String>()
            for (url in listOf("https://www.gstatic.com/generate_204",
                    "https://cp.cloudflare.com/generate_204")) {
                if (token != generation) break
                val request = network.openConnection(URL(url)) as HttpsURLConnection
                pending = request
                request.connectTimeout = 2300
                request.readTimeout = 2300
                request.instanceFollowRedirects = false
                request.useCaches = false
                val deadline = timer.schedule({ request.disconnect() }, 3, TimeUnit.SECONDS)
                try {
                    check(request.responseCode == 204) { "HTTP status" }
                    if (token != generation) break
                    val latency = SystemClock.elapsedRealtime() - start
                    return mapOf("delay" to latency, "latencyMs" to latency,
                        "httpsVerified" to true, "quality" to false,
                        "detail" to "HTTPS через системный VPN подтверждён; скорость проверяется отдельно")
                } catch (e: Exception) {
                    failures.add("${URL(url).host}: ${ProbeFailure.describe(e)}")
                } finally {
                    deadline.cancel(false)
                    request.disconnect()
                    if (pending === request) pending = null
                }
            }
            return mapOf("delay" to -1L,
                "detail" to "HTTPS через VPN не подтверждён: ${failures.joinToString("; ")}")
        }
        var latencyMs = -1L // HTTPS 204 only; never include the subsequent 256-KiB transfer.
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
                        latencyMs = SystemClock.elapsedRealtime() - start
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
                            "latencyMs" to latencyMs, "quality" to false, "bytesPerSecond" to bps,
                            "detail" to "VPN работает, но тест медленный: ${bps / 1024} КиБ/с. Сохранён как резервный кандидат (цель 128 КиБ/с)")
                        return mapOf("delay" to SystemClock.elapsedRealtime() - start, "latencyMs" to latencyMs,
                            "bytesPerSecond" to bps, "quality" to true,
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

