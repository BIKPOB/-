package app.quietvpn.quiet_vpn

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities as NC
import android.os.SystemClock
import org.json.JSONObject
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

/** Application-owned observer; no VPN configuration or user traffic is inspected. */
object NetworkBaselineStore {
    private val worker = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var pending: HttpsURLConnection? = null
    @Volatile private var paused = false
    @Volatile private var epoch = 0
    private fun prefs(c: Context) = c.getSharedPreferences("network-baseline", Context.MODE_PRIVATE)
    fun whenIdle(done: () -> Unit) { worker.execute { done() } }
    fun cancel() { epoch++; pending?.disconnect() }
    fun pause(value: Boolean) { paused = value; if (value) { epoch++; pending?.disconnect() } }
    fun read(c: Context): Map<String, Any>? = try {
        val p = prefs(c)
        val boot = android.provider.Settings.Global.getInt(c.contentResolver, android.provider.Settings.Global.BOOT_COUNT, -1)
        check(boot >= 0 && p.getInt("sampleBoot", -2) == boot)
        val j = JSONObject(p.getString("sample", "") ?: "")
        j.keys().asSequence().associateWith { j.get(it) }
    } catch (_: Exception) { null }
    fun schedule(c: Context) {
        val scheduler = c.getSystemService(JobScheduler::class.java)
        if (scheduler.getPendingJob(7542) == null) scheduler.schedule(
            JobInfo.Builder(7542, ComponentName(c, NetworkBaselineJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setRequiresBatteryNotLow(true)
                .setPeriodic(15 * 60 * 1000L).setPersisted(true).build())
    }
    fun request(c: Context, done: () -> Unit = {}) { worker.execute { try { measure(c) } catch (_: Exception) { } finally { done() } } }
    private fun measure(c: Context) {
        val token = epoch
        if (paused) return
        val cm = c.getSystemService(ConnectivityManager::class.java)
        if (cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NC.TRANSPORT_VPN) == true }) return
        val network = cm.activeNetwork ?: return
        val caps = cm.getNetworkCapabilities(network) ?: return
        if (!caps.hasCapability(NC.NET_CAPABILITY_VALIDATED) || caps.hasTransport(NC.TRANSPORT_VPN)) return
        val limited = !caps.hasCapability(NC.NET_CAPABILITY_NOT_METERED)
        if (android.os.Build.VERSION.SDK_INT >= 28 && !caps.hasCapability(NC.NET_CAPABILITY_NOT_ROAMING)) return
        val p = prefs(c)
        val now = System.currentTimeMillis()
        val interval = (if (limited) 120 else 30) * 60 * 1000L
        val age = now - p.getLong("attempt", 0)
        if (age < 5 * 60 * 1000L || (p.getString("attemptSession", "") == network.networkHandle.toString() && age < interval)) return
        val day = now / 86400000L
        val used = if (p.getLong("day", -1) == day) p.getInt("used", 0) else 0
        val size = (if (limited) 1 else 4) * 1048576
        if (used + size > (if (limited) 8 else 32) * 1048576) return
        p.edit().putLong("attempt", now).putLong("day", day).putInt("used", used + size).putString("attemptSession", network.networkHandle.toString()).commit()
        val request = network.openConnection(URL("https://speed.cloudflare.com/__down?bytes=$size")) as HttpsURLConnection
        pending = request
        val deadline = timer.schedule({ request.disconnect() }, 12, TimeUnit.SECONDS)
        try {
            check(token == epoch && !paused)
            request.connectTimeout = 5000; request.readTimeout = 5000
            request.instanceFollowRedirects = false
            request.setRequestProperty("Accept-Encoding", "identity")
            val start = SystemClock.elapsedRealtime()
            check(request.responseCode == 200)
            val latency = SystemClock.elapsedRealtime() - start
            val transfer = SystemClock.elapsedRealtime()
            var bytes = 0
            request.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (bytes < size) {
                    check(token == epoch && !paused && cm.activeNetwork == network && SystemClock.elapsedRealtime() - start < 12000)
                    check(cm.allNetworks.none { cm.getNetworkCapabilities(it)?.hasTransport(NC.TRANSPORT_VPN) == true })
                    val n = input.read(buffer, 0, minOf(buffer.size, size - bytes))
                    if (n < 0) break
                    bytes += n
                }
            }
            val elapsed = SystemClock.elapsedRealtime() - transfer
            check(bytes == size && elapsed >= 20 && token == epoch && cm.activeNetwork == network)
            val type = when { caps.hasTransport(NC.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NC.TRANSPORT_CELLULAR) -> "mobile"
                caps.hasTransport(NC.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other" }
            val result = JSONObject().put("session", NetworkSnapshot.session(c, network)).put("type", type)
                .put("time", now).put("bytesPerSecond", bytes * 1000L / elapsed).put("latencyMs", latency)
            p.edit().putString("sample", result.toString())
                .putInt("sampleBoot", android.provider.Settings.Global.getInt(c.contentResolver, android.provider.Settings.Global.BOOT_COUNT, -1)).commit()
        } catch (_: Exception) { /* Keep last sample; freshness is checked at use. */ }
        finally { deadline.cancel(false); request.disconnect(); if (pending === request) pending = null }
    }
}

class NetworkBaselineJob : JobService() {
    private var stopped = java.util.concurrent.atomic.AtomicBoolean(false)
    override fun onStartJob(params: JobParameters): Boolean {
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        stopped = cancelled
        NetworkBaselineStore.request(applicationContext) { if (!cancelled.get()) jobFinished(params, false) }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { stopped.set(true); NetworkBaselineStore.cancel(); return true }
}
