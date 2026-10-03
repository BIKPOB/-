package app.quietvpn.quiet_vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.config.Config
import java.io.ByteArrayInputStream
import java.util.concurrent.Executors

object WgSession {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    var sink: EventChannel.EventSink? = null
    var state = "disconnected"
    private var backend: GoBackend? = null
    private val tunnel = object : Tunnel {
        override fun getName() = "quietvpn"
        override fun onStateChange(value: Tunnel.State) {
            if (value == Tunnel.State.DOWN) emit("disconnected")
        }
    }
    private fun emit(value: String) { main.post { state = value; sink?.success(value) } }
    fun connect(activity: Activity, profile: String, result: MethodChannel.Result) {
        emit("connecting")
        worker.execute {
            try {
                val engine = backend ?: GoBackend(activity.applicationContext).also { backend = it }
                engine.setStatusCallback { connected -> if (connected) emit("connected") }
                val config = Config.parse(ByteArrayInputStream(profile.toByteArray(Charsets.UTF_8)))
                engine.setState(tunnel, Tunnel.State.UP, config)
                main.post { result.success(null) }
            } catch (_: Exception) {
                emit("error")
                main.post { result.error("WG_START", "Не удалось запустить WireGuard/AmneziaWG", null) }
            }
        }
    }
    fun stop(result: MethodChannel.Result) {
        worker.execute {
            try {
                backend?.setState(tunnel, Tunnel.State.DOWN, null)
                emit("disconnected")
                main.post { result.success(null) }
            } catch (_: Exception) { main.post { result.error("WG_STOP", "Отключение не подтверждено", null) } }
        }
    }
}

class WgBridge(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var profile: String? = null
    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "stage" -> result.success(WgSession.state)
            "stop" -> WgSession.stop(result)
            "start" -> {
                if (pending != null || WgSession.state != "disconnected") { result.error("BUSY", "Сначала отключите VPN", null); return }
                val text = call.argument<String>("profile")
                if (text == null || text.length > 131072) { result.error("PROFILE", "Некорректный профиль", null); return }
                val permission = VpnService.prepare(activity)
                if (permission == null) WgSession.connect(activity, text, result)
                else { pending = result; profile = text; activity.startActivityForResult(permission, 41) }
            }
            else -> result.notImplemented()
        }
    }
    fun permissionResult(code: Int) {
        val result = pending ?: return
        val text = profile ?: return
        pending = null; profile = null
        if (code == Activity.RESULT_OK) WgSession.connect(activity, text, result)
        else result.error("DENIED", "Разрешение VPN отклонено", null)
    }
}
