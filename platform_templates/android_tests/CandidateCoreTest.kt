package app.quietvpn.quiet_vpn

import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import dev.amirzr.flutter_v2ray_client.v2ray.core.QuietCandidateCore

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CandidateCoreTest {
    @Test fun onlyLoopbackProxyInboundsAreAccepted() {
        QuietCandidateCore.validate("""{"inbounds":[{"listen":"127.0.0.1","port":31001,"protocol":"http"}]}""")
        for (entry in listOf(
            """{"listen":"0.0.0.0","port":31001,"protocol":"http"}""",
            """{"listen":"127.0.0.1","port":31001,"protocol":"tun"}""",
            """{"listen":"127.0.0.1","port":80,"protocol":"http"}""")) {
            try {QuietCandidateCore.validate("""{"inbounds":[$entry]}"""); fail("Unsafe candidate inbound")}
            catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun networkPseudonymsAreLocalAndDistinct() {
        val a = NetworkIdentity.hash("install-a", "wifi|3")
        assertEquals(a, NetworkIdentity.hash("install-a", "wifi|3"))
        assertNotEquals(a, NetworkIdentity.hash("install-b", "wifi|3"))
        assertNotEquals(a, NetworkIdentity.hash("install-a", "wifi|4"))
        assertFalse(a.contains("wifi"))
    }
}
