package app.quietvpn.quiet_vpn

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config as RoboConfig

@RunWith(RobolectricTestRunner::class)
@RoboConfig(sdk = [34], application = QuietVpnApplication::class)
class SearchSessionServiceTest {
    @Test fun userInitiatedSearchCreatesVisibleForegroundNotificationAndStopsCleanly() {
        val controller = Robolectric.buildService(SearchSessionService::class.java).create()
        try {
            val service = controller.get()
            val result = service.onStartCommand(
                Intent(service, SearchSessionService::class.java)
                    .setAction(SearchSessionService.ACTION_START)
                    .putExtra("deep", true), 0, 1)
            assertEquals(android.app.Service.START_NOT_STICKY, result)
            val notifications = service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            assertTrue(notifications.activeNotifications.any {
                it.id == SearchSessionService.NOTIFICATION_ID &&
                    it.notification.extras.getString("android.title")?.contains("ИИ") == true
            })
            assertTrue(SearchSessionService.isRequested())
            val search = notifications.activeNotifications.first {
                it.id == SearchSessionService.NOTIFICATION_ID
            }.notification
            assertTrue(search.actions.any { it.title?.toString() == "Остановить" })
        } finally { controller.destroy() }
        assertFalse(SearchSessionService.isRequested())
    }
}
