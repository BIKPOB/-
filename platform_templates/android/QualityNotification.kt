package app.quietvpn.quiet_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import java.util.Locale

/** Uses a completed transfer test, never idle traffic counters, as evidence. */
object QualityNotification {
    const val ID = 5353
    fun update(context: Context, active: Boolean, speed: Long, target: Long) {
        try {
            val manager = context.getSystemService(NotificationManager::class.java)
            val serviceAlive = manager.activeNotifications.any { it.id == 1 || it.id == 5252 }
            if (!active || !serviceAlive || speed <= 0 || target <= 0 || speed >= target) {
                manager.cancel(ID)
                return
            }
            val channel = "quietvpn_quality"
            manager.createNotificationChannel(NotificationChannel(channel,
                "Предупреждения о скорости VPN", NotificationManager.IMPORTANCE_DEFAULT))
            val measured = String.format(Locale.ROOT, "%.1f", speed * 8 / 1000000.0)
            val desired = String.format(Locale.ROOT, "%.1f", target * 8 / 1000000.0)
            val advice = "Повторите подбор VPN-сервера или попробуйте другую сеть Wi-Fi / мобильного интернета."
            val text = "Последний замер: $measured Мбит/с, цель: $desired Мбит/с. $advice"
            val builder = Notification.Builder(context, channel)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("Quiet VPN: пониженная скорость")
                .setContentText(advice)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setOnlyAlertOnce(true).setAutoCancel(true)
                .setTimeoutAfter(5 * 60 * 1000L)
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) builder.setContentIntent(PendingIntent.getActivity(context,
                ID, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            manager.notify(ID, builder.build())
        } catch (_: Exception) { /* Denied notifications must not affect VPN. */ }
    }
    fun clear(context: Context) {
        try { context.getSystemService(NotificationManager::class.java).cancel(ID) }
        catch (_: Exception) { }
    }
}
