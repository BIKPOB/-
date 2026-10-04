package app.quietvpn.quiet_vpn

import android.app.Application
import de.blinkt.openvpn.core.GlobalPreferences

/** Initialize process-wide OpenVPN state before Android can create its service. */
class QuietVpnApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashDiagnostics.install(this)
        GlobalPreferences.setInstance(false, false, false)
    }
}
