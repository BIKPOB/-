package app.quietvpn.quiet_vpn

import android.app.ActivityManager
import android.content.Context
import android.os.Build

/** Local bounded diagnostic: exception types/frames only, never messages or VPN logs. */
object CrashDiagnostics {
    fun install(context: Context) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, failure ->
            try {
                context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE).edit()
                    .putString("last", sanitized(failure)).commit()
            } catch (_: Exception) {
                // Recording must not prevent Android's normal crash handling.
            } finally {
                if (previous != null) previous.uncaughtException(thread, failure)
                else android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }
    fun sanitized(failure: Throwable): String {
        val text = StringBuilder()
        var cause: Throwable? = failure
        repeat(4) {
            val current = cause ?: return@repeat
            text.append(current.javaClass.name).append('\n')
            current.stackTrace.take(24).forEach {
                text.append("  ").append(it.className).append('.').append(it.methodName)
                    .append(':').append(it.lineNumber).append('\n')
            }
            cause = if (current.cause === current) null else current.cause
        }
        return text.toString().take(16000)
    }
    fun report(context: Context): String {
        val text = StringBuilder("Quiet VPN 0.5.4\nAndroid ${Build.VERSION.RELEASE} / API ${Build.VERSION.SDK_INT}\n${Build.MANUFACTURER} ${Build.MODEL}\nABI: ${Build.SUPPORTED_ABIS.joinToString()}\n")
        text.append(context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE)
            .getString("last", "Перехваченных Java/Kotlin-сбоев нет.")).append('\n')
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                context.getSystemService(ActivityManager::class.java)
                    .getHistoricalProcessExitReasons(context.packageName, 0, 3).forEach {
                        text.append("Android exit: reason=${it.reason}, status=${it.status}, time=${it.timestamp}\n")
                    }
            } catch (_: Exception) { text.append("История завершений недоступна.\n") }
        }
        return text.toString()
    }
}
