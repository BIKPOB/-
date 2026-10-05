package app.quietvpn.quiet_vpn

import android.Manifest
import android.app.job.JobScheduler
import android.content.Context
import android.content.pm.PackageManager
import de.blinkt.openvpn.VpnProfile
import de.blinkt.openvpn.core.OpenVPNService
import de.blinkt.openvpn.core.ProfileManager
import de.blinkt.openvpn.core.keepVPNAlive
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = QuietVpnApplication::class)
class OpenVpnLifecycleTest {
    @Test fun startupDoesNotSchedulePersistedJobsWithoutBootPermission() {
        val context = RuntimeEnvironment.getApplication()
        assertEquals(PackageManager.PERMISSION_DENIED,
            context.packageManager.checkPermission(Manifest.permission.RECEIVE_BOOT_COMPLETED, context.packageName))
        val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        scheduler.cancelAll()
        keepVPNAlive.scheduleKeepVPNAliveJobService(context, VpnProfile("test"))
        assertTrue(scheduler.allPendingJobs.isEmpty())
    }
    @Test fun revokeBeforeManagementStartsDoesNotDereferenceNull() {
        ProfileManager.getInstance(RuntimeEnvironment.getApplication())
        val service = Robolectric.buildService(OpenVPNService::class.java).create()
        try { service.get().onRevoke() } finally { service.destroy() }
    }
    @Test fun tunnelCountersAreUnavailableAfterDisconnect() {
        OpenVpnSession.emit("connected")
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        OpenVpnSession.updateByteCount(4096L, 2048L, 0L, 0L)
        assertEquals(4096L, OpenVpnSession.traffic()?.get("received"))
        assertEquals(2048L, OpenVpnSession.traffic()?.get("sent"))
        OpenVpnSession.emit("disconnected")
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertNull(OpenVpnSession.traffic())
    }
    @Test fun diagnosticsExcludeExceptionMessagesAndSecretValues() {
        val secret = "PRIVATE_KEY_TEST_SENTINEL"
        val report = CrashDiagnostics.sanitized(IllegalStateException(secret, SecurityException(secret)))
        assertTrue(report.contains("java.lang.IllegalStateException"))
        assertTrue(report.contains("java.lang.SecurityException"))
        assertFalse(report.contains(secret))
        assertTrue(report.length <= 16000)
    }
}
