package app.quietvpn.quiet_vpn

import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** Explicit SOCKS proxy: never falls back to the application's direct network. */
object ProxyProbe {
    @Volatile private var pending: HttpsURLConnection? = null
    fun measure(): Long {
        val start = android.os.SystemClock.elapsedRealtime()
        val connection = URL("https://www.gstatic.com/generate_204").openConnection(
            Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", 10807))) as HttpsURLConnection
        pending = connection
        return try {
            connection.connectTimeout = 8000
            connection.readTimeout = 8000
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Connection", "close")
            if (connection.responseCode == 204) android.os.SystemClock.elapsedRealtime() - start else -1L
        } catch (_: Exception) { -1L }
        finally { connection.disconnect(); if (pending === connection) pending = null }
    }
    fun cancel() { pending?.disconnect(); pending = null }
}
