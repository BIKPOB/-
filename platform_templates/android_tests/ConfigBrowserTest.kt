package app.quietvpn.quiet_vpn
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 34], application = QuietVpnApplication::class)
class ConfigBrowserTest {
    @Test fun browserCanOpenAndCloseWithoutNativeVpnOrStoragePermissions() {
        val context = org.robolectric.RuntimeEnvironment.getApplication()
        val intent = android.content.Intent(context, ConfigBrowserActivity::class.java).putExtra("source", "vpnbook")
        val controller = org.robolectric.Robolectric.buildActivity(ConfigBrowserActivity::class.java, intent).create().start().resume()
        try { assertFalse(controller.get().isFinishing) }
        finally { controller.pause().stop().destroy() }
    }
    @Test fun unknownSourceClosesCleanly() {
        val controller = org.robolectric.Robolectric.buildActivity(ConfigBrowserActivity::class.java).create()
        try { assertTrue(controller.get().isFinishing) } finally { controller.destroy() }
    }

    @Test fun onlyExplicitHttpsOriginsCanDownloadProfiles() {
        assertTrue(ConfigBrowserPolicy.allowed("vpnbook", "https://www.vpnbook.com/freevpn/wireguard-vpn"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "http://www.vpnbook.com/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://www.vpnbook.com.evil.example/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://evil.example@www.vpnbook.com/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://www.vpnbook.com:444/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "file:///data/user/0/private"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://cp.amnezia.org/en"))
        assertTrue(ConfigBrowserPolicy.allowed("custom", "https://provider.example/account"))
        assertFalse(ConfigBrowserPolicy.allowed("custom", "http://provider.example/account"))
        assertFalse(ConfigBrowserPolicy.allowed("custom", "file:///data/local/profile"))
        assertFalse(ConfigBrowserPolicy.allowed("proton", "https://account.protonvpn.com"))

    }
    @Test fun rejectsHtmlAndOversizedPayloadBeforeFlutterChannel() {
        assertFalse(ConfigBrowserPolicy.config("<html>not a profile</html>"))
        assertTrue(ConfigBrowserPolicy.config("[Interface]\nPrivateKey = test\n[Peer]\n"))
        assertFalse(ConfigBrowserPolicy.config("[Interface]\n[Peer]\n" + "a".repeat(131073)))
        assertFalse(ConfigBrowserPolicy.config("[Interface]\n[Peer]\n\u0000"))
    }
}
