package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities as NC
import android.os.Build
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.Manifest
import android.content.pm.PackageManager

/** Metadata for the selected physical route; no SSID, phone number or hardware ID. */
object NetworkSnapshot {
    private val processSession = java.util.UUID.randomUUID().toString()
    fun session(context: Context, network: android.net.Network, mobile: MobileNetwork.Info? = null): String {
        val boot = android.provider.Settings.Global.getInt(context.contentResolver,
            android.provider.Settings.Global.BOOT_COUNT, -1)
        val caps = context.getSystemService(ConnectivityManager::class.java).getNetworkCapabilities(network)
        val identity = mobile ?: caps?.let { MobileNetwork.read(context, it) }
        val suffix = if (caps?.hasTransport(NC.TRANSPORT_CELLULAR) == true)
            ":mobile:${identity?.identity ?: "unknown"}" else ""
        return "${if (boot >= 0) boot.toString() else processSession}:${network.networkHandle}$suffix"
    }
    fun read(context: Context, extended: Boolean = false): Map<String, Any?> {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val vpns = cm.allNetworks.mapNotNull { cm.getNetworkCapabilities(it) }
            .filter { it.hasTransport(NC.TRANSPORT_VPN) }
        val vpnPresent = vpns.isNotEmpty()
        val ownVpn = Build.VERSION.SDK_INT >= 30 && vpns.any { it.ownerUid == android.os.Process.myUid() }
        val foreignVpn = if (Build.VERSION.SDK_INT >= 30)
            vpns.any { it.ownerUid != android.os.Process.myUid() } else null
        val physical = cm.allNetworks.mapNotNull { n -> cm.getNetworkCapabilities(n)?.let { n to it } }
            .filter { it.second.hasCapability(NC.NET_CAPABILITY_INTERNET) && !it.second.hasTransport(NC.TRANSPORT_VPN) }
        val chosen = try { BaseNetwork.select(cm) } catch (_: BaseNetworkException) { null }
        if (chosen == null) return mapOf(
            "type" to if (physical.isEmpty()) "offline" else "other",
            "session" to physical.map { it.first.networkHandle }.sorted().joinToString(","),
            "ambiguous" to physical.isNotEmpty(), "vpnPresent" to vpnPresent, "ownVpn" to ownVpn, "foreignVpn" to foreignVpn
        )
        val (network, caps) = chosen
        val signal = if (Build.VERSION.SDK_INT >= 29) caps.signalStrength.takeIf { it != Int.MIN_VALUE } else null
        var wifi: WifiInfo? = null
        val mobile = MobileNetwork.read(context, caps, extended)
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

        }
        return mapOf(
            "historyKey" to NetworkIdentity.read(context, caps, mobile),
            "vpnPresent" to vpnPresent, "ownVpn" to ownVpn, "foreignVpn" to foreignVpn,
            "extended" to extended,
            "phoneGranted" to (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED),
            "wifiMhz" to wifi?.frequency?.takeIf { it > 0 },
            "radio" to mobile?.radio,
            "operator" to mobile?.operator,
            "operatorName" to mobile?.name,
            "simOperator" to mobile?.simOperator,
            "simOperatorName" to mobile?.simName,
            "operatorSource" to mobile?.source,
            "mobileSignal" to mobile?.signal,
            "type" to when {
                caps.hasTransport(NC.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NC.TRANSPORT_CELLULAR) -> "mobile"
                caps.hasTransport(NC.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            },
            // Reject stale work after physical-route or active-data SIM changes.
            "session" to session(context, network, mobile),
            "signal" to (wifi?.rssi?.takeIf { it in -126..-1 } ?: signal),
            "downKbps" to caps.linkDownstreamBandwidthKbps.takeIf { it > 0 },
            "upKbps" to caps.linkUpstreamBandwidthKbps.takeIf { it > 0 },
            "metered" to !caps.hasCapability(NC.NET_CAPABILITY_NOT_METERED),
            "roaming" to if (Build.VERSION.SDK_INT >= 28) !caps.hasCapability(NC.NET_CAPABILITY_NOT_ROAMING) else null,
            "validated" to caps.hasCapability(NC.NET_CAPABILITY_VALIDATED)
        )
    }
}

