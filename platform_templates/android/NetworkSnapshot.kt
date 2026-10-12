package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities as NC
import android.os.Build
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.telephony.TelephonyManager
import android.telephony.SubscriptionManager
import android.Manifest
import android.content.pm.PackageManager

/** Read only at attempt boundaries; no addresses, SSIDs or device identifiers leave this class. */
object NetworkSnapshot {
    fun read(context: Context, extended: Boolean = false): Map<String, Any?> {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val active = cm.activeNetwork
        val activeCaps = active?.let { cm.getNetworkCapabilities(it) }
        val physical = cm.allNetworks.mapNotNull { n -> cm.getNetworkCapabilities(n)?.let { n to it } }
            .filter { it.second.hasCapability(NC.NET_CAPABILITY_INTERNET) && !it.second.hasTransport(NC.TRANSPORT_VPN) }
        // VPN capabilities expose underlying transport types, not public network handles.
        // When multiple physical networks match, report ambiguity instead of inventing a default.
        val candidates = if (activeCaps?.hasTransport(NC.TRANSPORT_VPN) == true) physical.filter {
            (it.second.hasTransport(NC.TRANSPORT_WIFI) && activeCaps.hasTransport(NC.TRANSPORT_WIFI)) ||
            (it.second.hasTransport(NC.TRANSPORT_CELLULAR) && activeCaps.hasTransport(NC.TRANSPORT_CELLULAR)) ||
            (it.second.hasTransport(NC.TRANSPORT_ETHERNET) && activeCaps.hasTransport(NC.TRANSPORT_ETHERNET))
        } else physical
        val chosen = physical.firstOrNull { it.first == active }
            ?: candidates.singleOrNull()
            ?: if (candidates.isEmpty()) physical.singleOrNull() else null
        if (chosen == null) return mapOf(
            "type" to if (physical.isEmpty()) "offline" else "other",
            "session" to physical.map { it.first.networkHandle }.sorted().joinToString(","),
            "ambiguous" to physical.isNotEmpty()
        )
        val (network, caps) = chosen
        val signal = if (Build.VERSION.SDK_INT >= 29) caps.signalStrength.takeIf { it != Int.MIN_VALUE } else null
        var wifi: WifiInfo? = null
        var radio: Int? = null
        var mobileSignal: Int? = null
        var operator: String? = null
        if (extended) {
            if (caps.hasTransport(NC.TRANSPORT_WIFI)) {
                try {
                    wifi = if (Build.VERSION.SDK_INT >= 29) caps.transportInfo as? WifiInfo else null
                    if (wifi == null) {
                        @Suppress("DEPRECATION")
                        val legacy = context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo
                        wifi = legacy
                    }
                } catch (_: Exception) { }
            }
            if (caps.hasTransport(NC.TRANSPORT_CELLULAR) &&
                context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
                try {
                    val sub = if (Build.VERSION.SDK_INT >= 30) SubscriptionManager.getActiveDataSubscriptionId()
                        else SubscriptionManager.getDefaultDataSubscriptionId()
                    if (SubscriptionManager.isValidSubscriptionId(sub)) {
                        val tm = context.getSystemService(TelephonyManager::class.java).createForSubscriptionId(sub)
                        radio = tm.dataNetworkType.takeIf { it != TelephonyManager.NETWORK_TYPE_UNKNOWN }
                        operator = tm.networkOperator.takeIf { it.matches(Regex("[0-9]{5,6}")) }
                        if (Build.VERSION.SDK_INT >= 28) mobileSignal = tm.signalStrength?.level
                    }
                } catch (_: Exception) { }
            }
        }
        return mapOf(
            "extended" to extended,
            "phoneGranted" to (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED),
            "wifiMhz" to wifi?.frequency?.takeIf { it > 0 },
            "radio" to radio,
            "operator" to operator,
            "mobileSignal" to mobileSignal,
            "type" to when {
                caps.hasTransport(NC.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NC.TRANSPORT_CELLULAR) -> "mobile"
                else -> "other"
            },
            // Used only to cancel a search when Wi-Fi changes to another Wi-Fi; never persisted.
            "session" to network.networkHandle.toString(),
            "signal" to (wifi?.rssi?.takeIf { it in -126..-1 } ?: signal),
            "downKbps" to caps.linkDownstreamBandwidthKbps.takeIf { it > 0 },
            "upKbps" to caps.linkUpstreamBandwidthKbps.takeIf { it > 0 },
            "metered" to !caps.hasCapability(NC.NET_CAPABILITY_NOT_METERED),
            "roaming" to if (Build.VERSION.SDK_INT >= 28) !caps.hasCapability(NC.NET_CAPABILITY_NOT_ROAMING) else null,
            "validated" to caps.hasCapability(NC.NET_CAPABILITY_VALIDATED)
        )
    }
}
