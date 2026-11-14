package app.quietvpn.quiet_vpn

import android.Manifest
import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities as NC
import android.net.NetworkInfo
import android.telephony.TelephonyManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetworkCapabilities
import org.robolectric.shadows.ShadowNetworkInfo
import org.robolectric.shadows.ShadowSubscriptionManager

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@Suppress("DEPRECATION")
class MobileNetworkTest {
    private fun caps(transport: Int): NC = ShadowNetworkCapabilities.newInstance().also {
        shadowOf(it).addTransportType(transport)
        shadowOf(it).addCapability(NC.NET_CAPABILITY_INTERNET)
    }
    @Test fun activeDataWinsOverDefaultAndMissingActiveDoesNotGuess() {
        assertEquals(2, MobileNetwork.chooseSubscription(null, 2, 1, true))
        assertEquals(3, MobileNetwork.chooseSubscription(3, 2, 1, true))
        assertNull(MobileNetwork.chooseSubscription(null, -1, 1, true))
        assertEquals(1, MobileNetwork.chooseSubscription(null, -1, 1, false))
    }
    @Test fun basicSnapshotReadsActiveCarrierWithoutExtendedModeOrPhonePermission() {
        val app = RuntimeEnvironment.getApplication<Application>()
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        val tm = app.getSystemService(TelephonyManager::class.java)
        ShadowSubscriptionManager.setDefaultDataSubscriptionId(1)
        ShadowSubscriptionManager.setActiveDataSubscriptionId(2)
        shadowOf(tm).setTelephonyManagerForSubscriptionId(2, tm)
        shadowOf(tm).setNetworkOperator("25099")
        shadowOf(tm).setNetworkOperatorName("Beeline")
        shadowOf(tm).setSimOperator("25001")
        shadowOf(tm).setSimOperatorName("MTS")
        val cm = app.getSystemService(ConnectivityManager::class.java)
        shadowOf(cm).clearAllNetworks()
        shadowOf(cm).setActiveNetworkInfo(ShadowNetworkInfo.newInstance(
            NetworkInfo.DetailedState.CONNECTED, ConnectivityManager.TYPE_MOBILE, 0, true, true))
        val network = cm.activeNetwork!!
        shadowOf(cm).setNetworkCapabilities(network, caps(NC.TRANSPORT_CELLULAR))
        val snapshot = NetworkSnapshot.read(app)
        assertEquals("25099", snapshot["operator"])
        assertEquals("Beeline", snapshot["operatorName"])
        assertEquals("25001", snapshot["simOperator"])
        assertEquals("active-data", snapshot["operatorSource"])
        assertEquals(false, snapshot["extended"])
        assertNull(snapshot["radio"])
        assertNotNull(snapshot["historyKey"])
        val previous = snapshot["session"]
        val identity = snapshot["historyKey"]
        ShadowSubscriptionManager.setActiveDataSubscriptionId(3)
        shadowOf(tm).setTelephonyManagerForSubscriptionId(3, tm)
        val switched = NetworkSnapshot.read(app)
        assertNotEquals(previous, switched["session"])
        assertNotEquals(identity, switched["historyKey"])
        assertNull(MobileNetwork.read(app, caps(NC.TRANSPORT_WIFI)))
        ShadowSubscriptionManager.setActiveDataSubscriptionId(-1)
        assertNull(NetworkSnapshot.read(app)["operator"])
    }
}
