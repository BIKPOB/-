package app.quietvpn.quiet_vpn

import android.Manifest
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import org.amnezia.awg.config.Config
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config as RoboConfig

@RunWith(RobolectricTestRunner::class)
@RoboConfig(sdk = [34], application = QuietVpnApplication::class)
class BypassAppsTest {
    private val profile = """[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
DNS = 1.1.1.1
Jc = 4
[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
"""
    @Test fun realWireGuardParserReceivesExclusionsAndPreservesTunnel() {
        val routed = BypassApps.wireGuardProfile(profile, listOf("com.example.browser", "com.example.bank"))
        val config = Config.parse(routed.byteInputStream())
        assertEquals(setOf("com.example.browser", "com.example.bank"), config.`interface`.excludedApplications)
        assertEquals(4, config.`interface`.junkPacketCount.get().toInt())
        assertEquals(1, config.peers.size)
        assertTrue(Config.parse(BypassApps.wireGuardProfile(routed, emptyList()).byteInputStream()).`interface`.excludedApplications.isEmpty())
    }
    @Test fun sharedUidSelectionPersistsAndOwnProcessCannotBeExcluded() {
        val context = RuntimeEnvironment.getApplication() as Context
        val pm = shadowOf(context.packageManager)
        for (name in listOf("com.example.one", "com.example.two")) {
            pm.installPackage(PackageInfo().apply {
                packageName = name
                applicationInfo = ApplicationInfo().apply { packageName = name; uid = 10123 }
                requestedPermissions = arrayOf(Manifest.permission.INTERNET)
                requestedPermissionsFlags = intArrayOf(PackageInfo.REQUESTED_PERMISSION_GRANTED)
            })
        }
        BypassApps.save(context, listOf("com.example.one"))
        assertEquals(listOf("com.example.one", "com.example.two"), BypassApps.selected(context))
        assertThrows(IllegalArgumentException::class.java) { BypassApps.save(context, listOf(context.packageName)) }
        BypassApps.save(context, emptyList())
        assertTrue(BypassApps.selected(context).isEmpty())
    }
    @Test fun packageNamesCannotInjectConfiguration() {
        assertThrows(IllegalArgumentException::class.java) {
            BypassApps.wireGuardProfile(profile, listOf("com.example.app\nDNS = 9.9.9.9"))
        }
    }
}
