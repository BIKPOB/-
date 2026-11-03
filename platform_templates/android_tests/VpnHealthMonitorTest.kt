package app.quietvpn.quiet_vpn

import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = QuietVpnApplication::class)
class VpnHealthMonitorTest {
    @Test fun unexpectedDropRemainsVisibleUntilExplicitDisconnect() {
        val context = RuntimeEnvironment.getApplication() as Context
        VpnHealthMonitor.stop(context)
        assertEquals("", VpnHealthMonitor.status(context)["message"])
        VpnHealthMonitor.reportDrop(context)
        assertTrue(VpnHealthMonitor.status(context)["message"].toString().contains("переподключитесь"))
        // Native disconnect/state updates must not erase the user's recovery action.
        VpnHealthMonitor.configure(context, false, 625000)
        assertTrue(VpnHealthMonitor.status(context)["message"].toString().isNotEmpty())
        VpnHealthMonitor.stop(context)
        assertEquals("", VpnHealthMonitor.status(context)["message"])
    }
}
