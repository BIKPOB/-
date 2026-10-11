package app.quietvpn.quiet_vpn

import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TunnelRoutingTest {
    @Test fun dependencyMustNotInjectDanglingOrDirectDnsRules() {
        val input = """{"inbounds":[],"outbounds":[{"tag":"proxy"},{"tag":"dns"}],
            "dns":{"servers":["https://1.1.1.1/dns-query"]},
            "routing":{"rules":[{"type":"field","inboundTag":["tun"],"port":"53","outboundTag":"dns"}]}}"""
        val config = JSONObject(Utilities.ensureTunInbound(Utilities.ensureTunInbound(input, 1280), 1280))
        val rules = config.getJSONObject("routing").getJSONArray("rules")
        assertEquals(1, rules.length())
        assertEquals("dns", rules.getJSONObject(0).getString("outboundTag"))
        assertEquals(1, config.getJSONArray("inbounds").length())
        assertEquals(1280, config.getJSONArray("inbounds").getJSONObject(0).getJSONObject("settings").getInt("MTU"))
        assertFalse(config.toString().contains("direct"))
    }
    @Test fun completeButSlowDownloadsDoNotPassSelection() {
        assertFalse(TunnelProbe.acceptable(0, 1))
        assertFalse(TunnelProbe.acceptable(262143, 100))
        assertFalse(TunnelProbe.acceptable(262144, 5000))
        assertTrue(TunnelProbe.acceptable(262144, 1000))
    }
}
