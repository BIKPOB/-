package app.quietvpn.quiet_vpn

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import android.system.ErrnoException
import android.system.OsConstants
import java.net.SocketException
import java.security.cert.CertificateException
import javax.net.ssl.SSLHandshakeException

@RunWith(RobolectricTestRunner::class)
class ProbeFailureTest {
    @Test fun preservesCauseAndErrnoWithoutSecretMessages() {
        val outer = SocketException("secret-server-address")
        outer.initCause(ErrnoException("secret", OsConstants.EPERM))
        val result = ProbeFailure.describe(outer)
        assertTrue(result.contains("SocketException"))
        assertTrue(result.contains("ErrnoException errno=${OsConstants.EPERM}"))
        assertFalse(result.contains("secret"))
    }
    @Test fun distinguishesCertificateFailureWithoutCertificateContents() {
        val error = SSLHandshakeException("secret-certificate")
        error.initCause(CertificateException("secret-host"))
        assertEquals("SSLHandshakeException → CertificateException", ProbeFailure.describe(error))
    }
}
