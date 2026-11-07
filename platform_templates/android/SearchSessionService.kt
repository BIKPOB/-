package app.quietvpn.quiet_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/**
 * Only runs while the user has explicitly started an AI server search.
 * Keeps its Flutter process eligible to run when the screen is locked.
 * The partial CPU wake lock is bounded and never used for idle monitoring.
 */
class SearchSessionService : Service() {
    companion object {
        const val ACTION_START = "app.quietvpn.quiet_vpn.SEARCH_START"
        private const val CHANNEL = "quietvpn_search"
        const val NOTIFICATION_ID = 8342
        const val QUICK_MAX_MS = 45_000L
        const val DEEP_MAX_MS = 12 * 60_000L + 30_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val expire = Runnable { stopSelf() }
    private var cpuLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            stopSelf()
            return START_NOT_STICKY
        }
        val deep = intent.getBooleanExtra("deep", false)
        val maxMs = if (deep) DEEP_MAX_MS else QUICK_MAX_MS
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL, "Quiet VPN · ИИ-подбор", NotificationManager.IMPORTANCE_LOW))
        val openApp = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_quiet)
            .setContentTitle("Quiet VPN · ИИ-подбор")
            .setContentText("Поиск серверов продолжается при выключенном экране")
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        main.removeCallbacks(expire)
        if (cpuLock?.isHeld == true) cpuLock?.release()
        cpuLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "quietvpn:ai-search")
            .apply {
                setReferenceCounted(false)
                acquire(maxMs) // Android releases this even if Flutter stops responding.
            }
        main.postDelayed(expire, maxMs)
        return START_NOT_STICKY // No unattended restart after system kills the search.
    }

    override fun onDestroy() {
        main.removeCallbacks(expire)
        if (cpuLock?.isHeld == true) cpuLock?.release()
        cpuLock = null
        super.onDestroy()
    }
}
