package app.quietvpn.quiet_vpn
import android.app.Application
class QuietVpnApplication : Application() {
    override fun onCreate() { super.onCreate(); CrashDiagnostics.install(this) }
}
