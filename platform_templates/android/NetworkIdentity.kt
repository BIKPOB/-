package app.quietvpn.quiet_vpn

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.NetworkCapabilities as NC
import android.net.wifi.WifiManager
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager

/** Pseudonyms stay on this installation. No SSID, MAC, IMEI or cell ID is read. */
object NetworkIdentity {
    fun hash(salt: String, value: String): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest("$salt|$value".toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun read(context: Context, caps: NC): String? = try {
        val local = when {
            caps.hasTransport(NC.TRANSPORT_WIFI) -> {
                @Suppress("DEPRECATION")
                val id = context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo?.networkId ?: -1
                if (id < 0) null else "wifi|$id"
            }
            caps.hasTransport(NC.TRANSPORT_CELLULAR) && context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED -> {
                val sub = if (Build.VERSION.SDK_INT >= 30) SubscriptionManager.getActiveDataSubscriptionId()
                    else SubscriptionManager.getDefaultDataSubscriptionId()
                if (!SubscriptionManager.isValidSubscriptionId(sub)) null else {
                    val tm = context.getSystemService(TelephonyManager::class.java).createForSubscriptionId(sub)
                    val op = tm.networkOperator
                    if (op.isNullOrBlank()) null else "mobile|$sub|$op"
                }
            }
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
