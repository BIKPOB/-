package app.quietvpn.quiet_vpn

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject

object CatalogCache {
    const val MAX_BYTES = 2 * 1024 * 1024
    val sources = mapOf(
        "Au1rxx/free-vpn-subscriptions" to "https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/v2ray-base64.txt",
        "NiREvil/vless" to "https://raw.githubusercontent.com/NiREvil/vless/refs/heads/main/sub/v2rayng-wg.txt",
        "0xRadikal/Free-v2ray-Configs verified" to "https://raw.githubusercontent.com/0xRadikal/Free-v2ray-Configs/main/verified/configs.txt"
    )
    private fun cache(context: Context, source: String, validated: Boolean): AtomicFile {
        val index = sources.keys.indexOf(source)
        require(index >= 0)
        return AtomicFile(File(context.noBackupFilesDir, "catalog-$index-${if (validated) "validated" else "candidate"}.json"))
    }
    @Synchronized fun save(context: Context, source: String, text: String, validated: Boolean) {
        require(text.toByteArray(Charsets.UTF_8).size in 1..MAX_BYTES)
        val file = cache(context, source, validated)
        val data = JSONObject().put("text", text).put("updated", System.currentTimeMillis()).toString().toByteArray(Charsets.UTF_8)
        val stream = file.startWrite()
        try { stream.write(data); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
    }
    @Synchronized fun read(context: Context, source: String): List<Map<String, Any>> = listOf(false, true).mapNotNull { validated ->
        try {
            val json = JSONObject(String(cache(context, source, validated).readFully(), Charsets.UTF_8))
            mapOf("text" to json.getString("text"), "updated" to json.getLong("updated"))
        } catch (_: Exception) { null }
    }.sortedByDescending { it["updated"] as Long }
    fun schedule(context: Context) {
        try {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (scheduler.getPendingJob(7541) == null) scheduler.schedule(
                JobInfo.Builder(7541, ComponentName(context, CatalogRefreshJob::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setPeriodic(6 * 60 * 60 * 1000L)
                    .setPersisted(true).build())
        } catch (_: Exception) { /* Foreground refresh remains available. */ }
    }
}

/** Updates lists only. Never restarts VPN or claims to renew provider credentials. */
class CatalogRefreshJob : JobService() {
    private val worker = Executors.newSingleThreadExecutor()
    private var task: Future<*>? = null
    private var cancelled = AtomicBoolean(false)
    @Volatile private var connection: HttpsURLConnection? = null
    override fun onStartJob(params: JobParameters): Boolean {
        val stopped = AtomicBoolean(false)
        cancelled = stopped
        task = worker.submit {
            var failed = false
            for ((source, address) in CatalogCache.sources) {
                if (stopped.get()) break
                val request = URL(address).openConnection() as HttpsURLConnection
                connection = request
                try {
                    request.connectTimeout = 8000; request.readTimeout = 8000
                    request.instanceFollowRedirects = false
                    val deadline = android.os.SystemClock.elapsedRealtime() + 25000
                    check(request.responseCode == 200)
                    val bytes = ByteArrayOutputStream()
                    request.inputStream.use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            check(!stopped.get() && android.os.SystemClock.elapsedRealtime() < deadline)
                            val count = input.read(buffer)
                            if (count < 0) break
                            check(bytes.size() + count <= CatalogCache.MAX_BYTES)
                            bytes.write(buffer, 0, count)
                        }
                    }
                    check(!stopped.get())
                    // Candidate is parsed and validated in Dart before display/use.
                    CatalogCache.save(this, source, bytes.toString("UTF-8"), false)
                } catch (_: Exception) { failed = true }
                finally { request.disconnect(); connection = null }
            }
            if (!stopped.get()) jobFinished(params, failed)
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean {
        cancelled.set(true); connection?.disconnect(); task?.cancel(true)
        return true
    }
    override fun onDestroy() {
        cancelled.set(true); connection?.disconnect(); worker.shutdownNow(); super.onDestroy()
    }
}
