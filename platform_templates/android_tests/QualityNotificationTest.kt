package app.quietvpn.quiet_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = QuietVpnApplication::class)
class QualityNotificationTest {
    @Test fun onlyMeasuredSlowActiveVpnWarnsAndRecoveryClearsIt() {
        val context = RuntimeEnvironment.getApplication() as Context
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancelAll()
        QualityNotification.update(context, true, 100000, 625000)
        assertNull(manager.activeNotifications.firstOrNull { it.id == QualityNotification.ID })
        manager.createNotificationChannel(NotificationChannel("test-vpn", "VPN", NotificationManager.IMPORTANCE_LOW))
        manager.notify(1, Notification.Builder(context, "test-vpn")
            .setSmallIcon(android.R.drawable.stat_sys_warning).build())
        QualityNotification.update(context, true, 0, 625000)
        assertNull(manager.activeNotifications.firstOrNull { it.id == QualityNotification.ID })
        QualityNotification.update(context, true, 100000, 625000)
        val warning = manager.activeNotifications.first { it.id == QualityNotification.ID }.notification
        assertTrue(warning.extras.getCharSequence(Notification.EXTRA_BIG_TEXT).toString().contains("другую сеть"))
        assertEquals(300000L, warning.timeoutAfter)
        QualityNotification.update(context, true, 700000, 625000)
        assertNull(manager.activeNotifications.firstOrNull { it.id == QualityNotification.ID })
        QualityNotification.update(context, true, 100000, 625000)
        QualityNotification.update(context, false, 100000, 625000)
        assertNull(manager.activeNotifications.firstOrNull { it.id == QualityNotification.ID })
    }
}
