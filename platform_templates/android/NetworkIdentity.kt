package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.NetworkCapabilities as NC
import android.net.wifi.WifiManager

/** Pseudonyms stay on this installation. No SSID, MAC, IMEI or cell ID is read. */
object NetworkIdentity {
    fun hash(salt: String, value: String): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest("$salt|$value".toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun read(context: Context, caps: NC, mobile: MobileNetwork.Info? = MobileNetwork.read(context, caps)): String? = try {
        val local = when {
            caps.hasTransport(NC.TRANSPORT_WIFI) -> {
                @Suppress("DEPRECATION")
                val id = context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo?.networkId ?: -1
                if (id < 0) null else "wifi|$id"
            }
            caps.hasTransport(NC.TRANSPORT_CELLULAR) -> mobile?.let { "mobile|${it.identity}" }
            else -> null
        }
        if (local == null) null else {
            val prefs = context.getSharedPreferences("network-identity", Context.MODE_PRIVATE)
            val salt = prefs.getString("salt", null) ?: java.util.UUID.randomUUID().toString().also {
                prefs.edit().putString("salt", it).commit()
            }
            hash(salt, local)
        }
    } catch (_: Exception) { null }
}

