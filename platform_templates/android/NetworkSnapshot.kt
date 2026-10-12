package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities as NC
import android.os.Build

/** Read only at attempt boundaries; no addresses, SSIDs or device identifiers leave this class. */
object NetworkSnapshot {
    fun read(context: Context): Map<String, Any?> {
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
        return mapOf(
            "type" to when {
                caps.hasTransport(NC.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NC.TRANSPORT_CELLULAR) -> "mobile"
                else -> "other"
            },
            // Used only to cancel a search when Wi-Fi changes to another Wi-Fi; never persisted.
            "session" to network.networkHandle.toString(),
            "signal" to signal,
            "downKbps" to caps.linkDownstreamBandwidthKbps.takeIf { it > 0 },
            "upKbps" to caps.linkUpstreamBandwidthKbps.takeIf { it > 0 },
            "metered" to !caps.hasCapability(NC.NET_CAPABILITY_NOT_METERED),
            "roaming" to if (Build.VERSION.SDK_INT >= 28) !caps.hasCapability(NC.NET_CAPABILITY_NOT_ROAMING) else null,
            "validated" to caps.hasCapability(NC.NET_CAPABILITY_VALIDATED)
        )
    }
}
