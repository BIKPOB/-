package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.InetSocketAddress

object EndpointProbe {
    /** Diagnostic only: TCP success does not authenticate a VPN server. */
    fun resolve(context: Context, host: String, port: Int): String {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val network = cm.activeNetwork ?: error("Нет базовой сети")
        val caps = cm.getNetworkCapabilities(network) ?: error("Нет параметров сети")
        check(!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) { "Предыдущий VPN ещё активен" }
        val type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "мобильная"
            else -> "другая"
        }
        XrayDiagnostics.endpointReport = "Базовая сеть: $type; разрешение адреса сервера"
        val addresses = network.getAllByName(host)
        val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.first()
        val tcp = try {
            network.socketFactory.createSocket().use { socket ->
                socket.connect(InetSocketAddress(address, port), 3000)
            }
            "TCP до VPN: доступен (протокол и ключи ещё не проверены)"
        } catch (e: Exception) { "TCP до VPN: ${e.javaClass.simpleName} (сам по себе не доказывает блокировку)" }
        XrayDiagnostics.endpointReport = "Базовая сеть: $type; адрес сервера разрешён; $tcp"
        return address.hostAddress ?: error("Нет IP")
    }
}
