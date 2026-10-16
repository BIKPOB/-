package app.quietvpn.quiet_vpn

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities as NC

class BaseNetworkException(val reason: String) : Exception(reason)

/** Same physical route selection for metadata and endpoint DNS/socket binding. */
object BaseNetwork {
    data class Candidate(val handle: Long, val transports: Set<Int>)
    fun choose(active: Long?, vpnTransports: Set<Int>?, physical: List<Candidate>): Long? {
        physical.firstOrNull { it.handle == active }?.let { return it.handle }
        val matching = if (vpnTransports == null) physical else physical.filter {
            it.transports.any { transport -> transport in vpnTransports }
        }
        return matching.singleOrNull()?.handle
            ?: if (matching.isEmpty()) physical.singleOrNull()?.handle else null
    }
    private fun transports(caps: NC) = setOf(NC.TRANSPORT_WIFI, NC.TRANSPORT_CELLULAR, NC.TRANSPORT_ETHERNET)
        .filter { caps.hasTransport(it) }.toSet()
    fun select(cm: ConnectivityManager): Pair<Network, NC> {
        val active = cm.activeNetwork
        val activeCaps = active?.let { cm.getNetworkCapabilities(it) }
        val physical = cm.allNetworks.mapNotNull { network ->
            cm.getNetworkCapabilities(network)?.let { network to it }
        }.filter { !it.second.hasTransport(NC.TRANSPORT_VPN) && it.second.hasCapability(NC.NET_CAPABILITY_INTERNET) }
        val chosen = choose(active?.networkHandle,
            if (activeCaps?.hasTransport(NC.TRANSPORT_VPN) == true) transports(activeCaps) else null,
            physical.map { Candidate(it.first.networkHandle, transports(it.second)) })
        return physical.firstOrNull { it.first.networkHandle == chosen }
            ?: throw BaseNetworkException(if (physical.isEmpty())
                "Android не предоставил доступную физическую сеть"
                else "Android предоставил несколько сетей: не удалось однозначно выбрать базовую")
    }
}
