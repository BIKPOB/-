package app.quietvpn.quiet_vpn
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ConfigBrowserTest {
    @Test fun onlyExplicitHttpsOriginsCanDownloadProfiles() {
        assertTrue(ConfigBrowserPolicy.allowed("vpnbook", "https://www.vpnbook.com/freevpn/wireguard-vpn"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "http://www.vpnbook.com/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://www.vpnbook.com.evil.example/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://evil.example@www.vpnbook.com/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://www.vpnbook.com:444/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "file:///data/user/0/private"))
        assertFalse(ConfigBrowserPolicy.allowed("vpnbook", "https://cp.amnezia.org/en"))
        assertTrue(ConfigBrowserPolicy.allowed("amnezia-mirror", "https://storage.googleapis.com/amnezia/cp?m-path=/en"))
        assertFalse(ConfigBrowserPolicy.allowed("amnezia-mirror", "https://storage.googleapis.com/other/file.conf"))
        assertFalse(ConfigBrowserPolicy.allowed("amnezia-mirror", "https://storage.googleapis.com/amnezia/cp-untrusted"))
    }
    @Test fun rejectsHtmlAndOversizedPayloadBeforeFlutterChannel() {
        assertFalse(ConfigBrowserPolicy.config("<html>not a profile</html>"))
        assertTrue(ConfigBrowserPolicy.config("[Interface]\nPrivateKey = test\n[Peer]\n"))
        assertFalse(ConfigBrowserPolicy.config("[Interface]\n[Peer]\n" + "a".repeat(131073)))
        assertFalse(ConfigBrowserPolicy.config("[Interface]\n[Peer]\n\u0000"))
    }
}
