package app.quietvpn.quiet_vpn

import android.content.Context
import android.util.AtomicFile
import dev.amirzr.flutter_v2ray_client.v2ray.core.QuietSocketDiagnostics
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SocketDiagnosticsTest {
    @Test fun reportReadsPersistedDaemonCountersInsteadOfUiStatics() {
        val context: Context = RuntimeEnvironment.getApplication()
        QuietSocketDiagnostics.start(context)
        QuietSocketDiagnostics.record(true)
        QuietSocketDiagnostics.record(false)
        assertArrayEquals(longArrayOf(1, 1), QuietSocketDiagnostics.read(context))
        // Simulate a different process updating disk while local statics stay 1/1.
        val file = AtomicFile(QuietSocketDiagnostics.path(context))
        val stream = file.startWrite()
        stream.write("17 3".toByteArray())
        file.finishWrite(stream)
        assertArrayEquals(longArrayOf(17, 3), QuietSocketDiagnostics.read(context))
        file.delete()
        assertNull(QuietSocketDiagnostics.read(context))
    }
}
