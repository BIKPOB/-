package app.quietvpn.quiet_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.SystemClock
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

/** Native worker in the VPN foreground-service process; independent of Flutter timers. */
object VpnHealthMonitor {
    private const val ID = 5454
    private val worker = Executors.newSingleThreadScheduledExecutor()
    private val deadlines = Executors.newSingleThreadScheduledExecutor()
    private var task: ScheduledFuture<*>? = null
    @Volatile private var epoch = 0
    @Volatile private var pending: HttpsURLConnection? = null
    @Volatile private var target = 625000L
    @Volatile private var notice = ""
    @Volatile private var checkedAt = 0L
    @Volatile private var watchedNetwork: Network? = null
    private var failures = 0
    private var recoveries = 0
    private var slowSamples = 0
    private var lastSpeedAt = 0L
    private fun prefs(context: Context) = context.getSharedPreferences("vpn-health", Context.MODE_PRIVATE)
    @Synchronized fun configure(context: Context, active: Boolean, desired: Long) {
        target = maxOf(625000L, desired)
        if (!active) { stop(context, false); return }
        if (task != null) return
        watchedNetwork = context.getSystemService(ConnectivityManager::class.java).allNetworks.firstOrNull {
            context.getSystemService(ConnectivityManager::class.java).getNetworkCapabilities(it)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
        clearNotice(context)
        val token = ++epoch
        failures = 0; recoveries = 0; slowSamples = 0
        lastSpeedAt = SystemClock.elapsedRealtime()
        val app = context.applicationContext
        task = worker.scheduleWithFixedDelay({
            try { check(app, token) } catch (_: Exception) { /* Retry on the next tick. */ }
        }, 30, 30, TimeUnit.SECONDS)
    }
    @Synchronized fun stop(context: Context, clear: Boolean = true) {
        epoch++; task?.cancel(false); task = null; pending?.disconnect(); pending = null
        if (clear) clearNotice(context)
    }
    fun status(context: Context): Map<String, Any> = mapOf("message" to (prefs(context).getString("notice", "") ?: ""), "checkedAt" to checkedAt)
    @Synchronized private fun clearNotice(context: Context) {
        notice = ""
        prefs(context).edit().remove("notice").apply()
        try { context.getSystemService(NotificationManager::class.java).cancel(ID) } catch (_: Exception) { }
    }
    @Synchronized fun reportDrop(context: Context) = warn(context,
        "VPN потерял соединение. Откройте Quiet VPN и переподключитесь или запустите подбор другого сервера.")
    private fun warn(context: Context, text: String) {
        notice = text
        prefs(context).edit().putString("notice", text).apply()
        try {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = "quietvpn_connection_health"
            manager.createNotificationChannel(NotificationChannel(channel,
                "Потеря связи VPN", NotificationManager.IMPORTANCE_DEFAULT))
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
            val action = PendingIntent.getActivity(context, ID, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            manager.notify(ID, Notification.Builder(context, channel)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("Quiet VPN: требуется проверка соединения")
                .setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(action).addAction(Notification.Action.Builder(null,
                    "Переподключиться", action).build())
                .setOnlyAlertOnce(true).setAutoCancel(true).build())
        } catch (_: Exception) { /* UI status still works without notification permission. */ }
    }
    private fun request(network: Network, address: String, bytes: Int, token: Int): Long {
        if (token != epoch) throw IllegalStateException("Stopped")
        val connection = network.openConnection(URL(address)) as HttpsURLConnection
        pending = connection
        val deadline = deadlines.schedule({ connection.disconnect() }, 8, TimeUnit.SECONDS)
        try {
            connection.connectTimeout = 5000; connection.readTimeout = 5000
            connection.instanceFollowRedirects = false; connection.useCaches = false
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (bytes == 0) {
                check(connection.responseCode == 204)
                return 1
            }
            check(connection.responseCode == 200)
            val start = SystemClock.elapsedRealtime()
            var received = 0
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (received < bytes) {
                    check(token == epoch)
                    val count = input.read(buffer, 0, minOf(buffer.size, bytes - received))
                    if (count < 0) break
                    received += count
                }
            }
            check(received == bytes)
            return received * 1000L / maxOf(1L, SystemClock.elapsedRealtime() - start)
        } finally { deadline.cancel(false); connection.disconnect(); if (pending === connection) pending = null }
    }
    private fun check(context: Context, token: Int) {
        if (token != epoch) return
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val network = watchedNetwork?.takeIf {
            cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
        val reachable = network != null && listOf("https://www.gstatic.com/generate_204",
            "https://cp.cloudflare.com/generate_204").any { address ->
            try { request(network, address, 0, token); true } catch (_: Exception) { false }
        }
        synchronized(this) {
            if (token != epoch) return
            checkedAt = System.currentTimeMillis()
            if (!reachable) {
                recoveries = 0; failures++
                if (failures >= 2) reportDrop(context)
                return
            }
            failures = 0; recoveries++
            if (recoveries >= 2 && slowSamples < 2) clearNotice(context)
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastSpeedAt < 5 * 60 * 1000L || network == null) return
        lastSpeedAt = now
        // At most 256 KiB per five minutes (~3 MiB/hour); never grade idle counters.
        val speed = try { request(network, "https://speed.cloudflare.com/__down?bytes=262144", 262144, token) }
                    catch (_: Exception) { 0L }
        synchronized(this) {
            if (token != epoch) return
            slowSamples = if (speed < target) slowSamples + 1 else 0
            if (slowSamples >= 2) warn(context,
                "Два фоновых замера ниже целевой скорости. Предлагаем переподключиться или подобрать другой VPN-сервер.")
            else if (speed >= target && recoveries >= 2) clearNotice(context)
        }
    }
}
