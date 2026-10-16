package app.quietvpn.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities as NC
import android.net.NetworkInfo
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkInfo
import org.robolectric.shadows.ShadowNetworkCapabilities

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@Suppress("DEPRECATION")
class BaseNetworkIntegrationTest {
    private fun info(type: Int) = ShadowNetworkInfo.newInstance(
        NetworkInfo.DetailedState.CONNECTED, type, 0, true, true)
    private fun capabilities(vararg transports: Int): NC {
        val caps = ShadowNetworkCapabilities.newInstance()
        shadowOf(caps).addCapability(NC.NET_CAPABILITY_INTERNET)
        transports.forEach { shadowOf(caps).addTransportType(it) }
        return caps
    }
    @Test fun metadataAndEndpointSelectionAgreeWithVpnAsDefault() {
        val context: Context = RuntimeEnvironment.getApplication()
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val shadow = shadowOf(cm)
        shadow.clearAllNetworks()
        shadow.setActiveNetworkInfo(info(ConnectivityManager.TYPE_VPN))
        val vpn = cm.activeNetwork!!
        shadow.setNetworkCapabilities(vpn, capabilities(NC.TRANSPORT_VPN, NC.TRANSPORT_WIFI))
        val wifi = ShadowNetwork.newInstance(ConnectivityManager.TYPE_WIFI)
        val mobile = ShadowNetwork.newInstance(ConnectivityManager.TYPE_MOBILE)
        shadow.addNetwork(wifi, info(ConnectivityManager.TYPE_WIFI))
        shadow.addNetwork(mobile, info(ConnectivityManager.TYPE_MOBILE))
        shadow.setNetworkCapabilities(wifi, capabilities(NC.TRANSPORT_WIFI))
        shadow.setNetworkCapabilities(mobile, capabilities(NC.TRANSPORT_CELLULAR))
        assertEquals(vpn, cm.activeNetwork)
        assertEquals(wifi, BaseNetwork.select(cm).first)
        val snapshot = NetworkSnapshot.read(context)
        assertEquals("wifi", snapshot["type"])
        assertEquals(wifi.networkHandle.toString(), snapshot["session"])
        shadow.setNetworkCapabilities(vpn, capabilities(NC.TRANSPORT_VPN, NC.TRANSPORT_CELLULAR))
        assertEquals(mobile, BaseNetwork.select(cm).first)
        assertEquals("mobile", NetworkSnapshot.read(context)["type"])
        shadow.removeNetwork(wifi)
        shadow.removeNetwork(mobile)
        try { BaseNetwork.select(cm); fail("VPN must never become its own base network") }
        catch (_: BaseNetworkException) { }
        assertEquals("offline", NetworkSnapshot.read(context)["type"])
    }
}
