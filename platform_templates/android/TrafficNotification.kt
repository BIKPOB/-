package app.quietvpn.quiet_vpn

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.SystemClock
import java.util.Locale

class TrafficRate {
    private var lastTime = 0L
    private var received = 0L
    private var sent = 0L
    fun reset() { lastTime = 0L; received = 0L; sent = 0L }
    fun sample(rx: Long, tx: Long, now: Long): String {
        val elapsed = now - lastTime
        val valid = lastTime > 0 && elapsed > 0 && rx >= received && tx >= sent
        val down = if (valid) (rx - received).toDouble() * 1000 / elapsed else 0.0
        val up = if (valid) (tx - sent).toDouble() * 1000 / elapsed else 0.0
        received = rx; sent = tx; lastTime = now
        return if (valid) "↓ ${format(down)}   ↑ ${format(up)}" else "↓ —   ↑ —"
    }
    companion object {
        fun format(value: Double): String = when {
            value >= 1048576 -> String.format(Locale.ROOT, "%.1f МиБ/с", value / 1048576)
            value >= 1024 -> String.format(Locale.ROOT, "%.1f КиБ/с", value / 1024)
            else -> String.format(Locale.ROOT, "%.0f Б/с", value)
        }
    }
}

/** Updates the service's existing notification; never resurrects a stopped VPN. */
class TrafficNotification(private val context: Context) {
    private val rate = TrafficRate()
    fun reset() = rate.reset()
    fun update(counters: Map<String, Long>?) {
        val text = if (counters == null) { rate.reset(); "↓ —   ↑ —" }
            else rate.sample(counters["received"] ?: 0L, counters["sent"] ?: 0L, SystemClock.elapsedRealtime())
        try {
            val manager = context.getSystemService(NotificationManager::class.java)
            val current = manager.activeNotifications.firstOrNull { it.id == 5252 } ?: return
            val notification = Notification.Builder.recoverBuilder(context, current.notification)
                .setContentText(text).setSubText("WireGuard · текущий трафик")
                .setOnlyAlertOnce(true).setShowWhen(false).build()
            manager.notify(5252, notification)
        } catch (_: Exception) { /* Notification permission does not control the tunnel. */ }
    }
}
