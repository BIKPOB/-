package app.quietvpn.quiet_vpn

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.config.Config
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config as RoboConfig

@RunWith(RobolectricTestRunner::class)
@RoboConfig(sdk = [34], application = QuietVpnApplication::class)
class WgSessionTest {
    private val profile = """[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
DNS = 1.1.1.1
[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
PersistentKeepalive = 25
"""
    private class Reply : MethodChannel.Result {
        var done = false
        var code: String? = null
        override fun success(value: Any?) { done = true }
        override fun error(code: String, message: String?, details: Any?) { this.code = code; done = true }
        override fun notImplemented() { done = true }
    }
    private class Fake : WgDriver {
        var failStart = false
        var failStop = false
        var handshake: (() -> Unit)? = null
        var config: Config? = null
        override fun start(config: Config, handshake: () -> Unit) {
            if (failStart) throw UnsatisfiedLinkError("test-only")
            this.config = config; this.handshake = handshake
        }
        override fun stop() { if (failStop) throw IllegalStateException("test-only") }
    }
    private fun waitFor(reply: Reply) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (!reply.done && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(5)
        }
        assertTrue("worker must complete", reply.done)
    }
    @Test fun realParsersPreserveWireGuardAndAmneziaFields() {
        for (awg in listOf(false, true)) {
            val fake = Fake()
            val controller = WgController(RuntimeEnvironment.getApplication()) { _, _ -> fake }
            try {
                val text = if (awg) profile.replace("[Peer]", "Jc = 4\nJmin = 40\nJmax = 70\nS1 = 10\nH1 = 123\nHeaderProtectionKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n[Peer]") else profile
                val reply = Reply(); controller.connect(text, reply); waitFor(reply)
                assertNull(reply.code)
                assertEquals("connecting", controller.state)
                val nativeConfig = fake.config!!.toAwgUserspaceString()
                assertTrue(nativeConfig.contains("endpoint=192.0.2.1:51820"))
                if (awg) { assertTrue(nativeConfig.contains("jc=4")); assertTrue(nativeConfig.contains("header_protection_key=")) }
                fake.handshake!!.invoke(); shadowOf(Looper.getMainLooper()).idle()
                assertEquals("connected", controller.state)
                val stop = Reply(); controller.stop(stop); waitFor(stop)
                fake.handshake!!.invoke(); shadowOf(Looper.getMainLooper()).idle()
                assertEquals("disconnected", controller.state)
            } finally { controller.closeForTest() }
        }
    }
    @Test fun libraryErrorAndMalformedConfigDoNotCrashAndAllowRetry() {
        val fake = Fake(); fake.failStart = true
        val controller = WgController(RuntimeEnvironment.getApplication()) { _, _ -> fake }
        try {
            val bad = Reply(); controller.connect("invalid", bad); waitFor(bad)
            assertEquals("WG_START", bad.code)
            val failed = Reply(); controller.connect(profile, failed); waitFor(failed)
            assertEquals("WG_LIBRARY", failed.code)
            fake.failStart = false
            val retry = Reply(); controller.connect(profile, retry); waitFor(retry)
            assertNull(retry.code)
            fake.failStop = true
            val stop = Reply(); controller.stop(stop); waitFor(stop)
            assertEquals("WG_STOP", stop.code)
            assertNotEquals("disconnected", controller.state)
            fake.failStop = false
            val retryStop = Reply(); controller.stop(retryStop); waitFor(retryStop)
            assertEquals("disconnected", controller.state)
        } finally { controller.closeForTest() }
    }
    @Test fun wireGuardServiceStartsForegroundNotification() {
        val service = Robolectric.buildService(GoBackend.VpnService::class.java).create()
        try {
            service.get().onStartCommand(Intent(service.get(), GoBackend.VpnService::class.java), 0, 1)
            val manager = service.get().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            assertTrue(manager.activeNotifications.any { it.id == 5252 })
        } finally { service.destroy() }
    }
}
