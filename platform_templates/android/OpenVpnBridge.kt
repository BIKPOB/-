package app.quietvpn.quiet_vpn

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.*
import android.net.VpnService
import android.os.*
import de.blinkt.openvpn.core.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.StringReader
import java.util.concurrent.Executors

/** Process-owned session; Activity recreation must not recreate or lose the tunnel. */
object OpenVpnSession : VpnStatus.StateListener {
    private val main = Handler(Looper.getMainLooper())
    val worker = Executors.newSingleThreadExecutor()
    var state = "disconnected"
        private set
    var sink: EventChannel.EventSink? = null
    private var initialized = false
    private var service: IOpenVPNServiceInternal? = null
    private val binding = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = IOpenVPNServiceInternal.Stub.asInterface(binder)
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            emit("disconnected")
        }
    }
    fun initialize(context: Context) {
        if (initialized) return
        val app = context.applicationContext
        val nm = app.getSystemService(NotificationManager::class.java)
        for (id in arrayOf(OpenVPNService.NOTIFICATION_CHANNEL_BG_ID,
            OpenVPNService.NOTIFICATION_CHANNEL_NEWSTATUS_ID,
            OpenVPNService.NOTIFICATION_CHANNEL_USERREQ_ID)) {
            nm.createNotificationChannel(NotificationChannel(id, "Quiet VPN", NotificationManager.IMPORTANCE_LOW))
        }
        VpnStatus.addStateListener(this)
        check(app.bindService(Intent(app, OpenVPNService::class.java).setAction(OpenVPNService.START_SERVICE), binding, Context.BIND_AUTO_CREATE))
        initialized = true
    }
    fun emit(value: String) { main.post { state = value; sink?.success(value) } }
    override fun setConnectedVPN(uuid: String?) {}
    override fun updateState(raw: String?, message: String?, resource: Int, level: ConnectionStatus?, intent: Intent?) {
        val next = when (level) {
            ConnectionStatus.LEVEL_CONNECTED -> "connected"
            ConnectionStatus.LEVEL_NOTCONNECTED -> "disconnected"
            ConnectionStatus.LEVEL_AUTH_FAILED -> "error"
            ConnectionStatus.LEVEL_WAITING_FOR_USER_INPUT -> "error"
            else -> if (raw == "NOPROCESS") "disconnected" else "connecting"
        }
        emit(next)
    }
    fun stop(result: MethodChannel.Result, attempt: Int = 0) {
        val current = service
        if (current == null && attempt < 20) {
            main.postDelayed({ stop(result, attempt + 1) }, 250); return
        }
        if (current == null) { result.error("stop", "VPN service unavailable", null); return }
        try {
            // A false result is not proof of disconnection during startup.
            current.stopVPN(false)
            result.success(null)
        } catch (_: Exception) { result.error("stop", "VPN stop failed", null) }
    }
}

class OpenVpnBridge(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var args: Map<String, String>? = null
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            OpenVpnSession.initialize(activity)
            when (call.method) {
                "stage" -> result.success(OpenVpnSession.state)
                "stop" -> OpenVpnSession.stop(result)
                "start" -> {
                    if (pending != null) { result.error("busy", "VPN permission pending", null); return }
                    val profile = call.argument<String>("profile") ?: throw IllegalArgumentException()
                    args = mapOf("profile" to profile, "name" to (call.argument<String>("name") ?: "Quiet VPN"),
                        "username" to (call.argument<String>("username") ?: ""), "password" to (call.argument<String>("password") ?: ""))
                    pending = result
                    val permission = VpnService.prepare(activity)
                    if (permission == null) launch() else activity.startActivityForResult(permission, 24)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            pending = null; args = null
            result.error("vpn", "Не удалось подготовить OpenVPN. Проверьте настройки другого VPN.", null)
        }
    }
    fun detach() {
        pending?.error("cancelled", "Запрос разрешения прерван. Повторите подключение.", null)
        pending = null; args = null
    }
    fun permissionResult(code: Int) {
        if (pending == null) return
        if (code == Activity.RESULT_OK) launch()
        else { pending?.error("permission", "Разрешение VPN отклонено", null); pending = null; args = null }
    }
    private fun launch() {
        val result = pending ?: return
        val config = args ?: return
        pending = null; args = null
        val context = activity.applicationContext
        OpenVpnSession.emit("connecting")
        OpenVpnSession.worker.execute {
            try {
                val parser = ConfigParser()
                parser.parseConfig(StringReader(config.getValue("profile")))
                val profile = parser.convertProfile()
                profile.mName = config.getValue("name")
                profile.mUsername = config.getValue("username")
                profile.mPassword = config.getValue("password")
                val error = profile.checkProfile(context)
                if (error != de.blinkt.openvpn.R.string.no_error_found) throw IllegalArgumentException()
                ProfileManager.getInstance(context)
                ProfileManager.setTemporaryProfile(context, profile)
                NativeUtils.getNativeAPI() // Fail on this guarded worker if JNI cannot load.
                VPNLaunchHelper.startOpenVpn(profile, context, "Quiet VPN", false)
                Handler(Looper.getMainLooper()).post { result.success(null) }
            } catch (_: LinkageError) {
                OpenVpnSession.emit("error")
                Handler(Looper.getMainLooper()).post { result.error("library", "VPN-библиотека несовместима с устройством", null) }
            } catch (_: Exception) {
                OpenVpnSession.emit("error")
                Handler(Looper.getMainLooper()).post { result.error("profile", "OpenVPN не смог запустить профиль", null) }
            }
        }
    }
}
