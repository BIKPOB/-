package app.quietvpn.quiet_vpn

import android.app.Activity
import android.content.Context
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

interface WgDriver {
    fun start(config: Config, handshake: () -> Unit)
    fun stop()
}

class NativeWgDriver(context: Context, disconnected: () -> Unit) : WgDriver {
    private val backend = GoBackend(context)
    private val tunnel = object : Tunnel {
        override fun getName() = "quietvpn"
        override fun onStateChange(value: Tunnel.State) {
            if (value == Tunnel.State.DOWN) disconnected()
        }
    }
    override fun start(config: Config, handshake: () -> Unit) {
        backend.setStatusCallback { connected -> if (connected) handshake() }
        backend.setState(tunnel, Tunnel.State.UP, config)
    }
    override fun stop() {
        backend.setStatusCallback(null)
        check(backend.setState(tunnel, Tunnel.State.DOWN, null) == Tunnel.State.DOWN)
    }
}

/** All state and event delivery are serialized on the Android main thread. */
class WgController(private val context: Context,
    private val factory: (Context, () -> Unit) -> WgDriver = { c, down -> NativeWgDriver(c, down) }) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var driver: WgDriver? = null
    private var generation = 0
    @Volatile private var driverGeneration = 0
    private var needsStop = false
    private var stopping = false
    var sink: EventChannel.EventSink? = null
    var state = "disconnected"
        private set
    private fun emit(value: String) { state = value; sink?.success(value) }
    fun connect(profile: String, result: MethodChannel.Result) {
        if (needsStop || stopping || state == "connecting") {
            result.error("BUSY", "Сначала отключите VPN", null); return
        }
        val token = ++generation
        needsStop = true
        emit("connecting")
        worker.execute {
            try {
                val config = Config.parse(ByteArrayInputStream(profile.toByteArray(Charsets.UTF_8)))
                val engine = driver ?: factory(context) {
                    val ended = driverGeneration
                    main.post { if (generation == ended && !stopping) { generation++; needsStop = false; emit("disconnected") } }
                }.also { driver = it }
                driverGeneration = token
                engine.start(config) {
                    main.post { if (generation == token && !stopping && state == "connecting") emit("connected") }
                }
                main.post { result.success(null) }
            } catch (_: LinkageError) {
                failed(token, result, "WG_LIBRARY", "VPN-библиотека несовместима с устройством. Обновите приложение.")
            } catch (_: Exception) {
                failed(token, result, "WG_START", "Не удалось запустить VPN. Проверьте конфигурацию и разрешение Android.")
            }
        }
    }
    private fun failed(token: Int, result: MethodChannel.Result, code: String, message: String) {
        var cleaned = false
        try {
            driver?.stop()
            context.stopService(Intent(context, GoBackend.VpnService::class.java))
            cleaned = true
        } catch (_: Exception) { } catch (_: LinkageError) { }
        main.post {
            if (generation == token && !stopping) { needsStop = !cleaned; emit("error") }
            result.error(code, message, null)
        }
    }
    fun stop(result: MethodChannel.Result) {
        generation++
        stopping = true
        worker.execute {
            try {
                driver?.stop()
                context.stopService(Intent(context, GoBackend.VpnService::class.java))
                main.post { stopping = false; needsStop = false; emit("disconnected"); result.success(null) }
            } catch (_: LinkageError) {
                main.post { stopping = false; result.error("WG_STOP", "Ошибка VPN-библиотеки при отключении", null) }
            } catch (_: Exception) {
                main.post { stopping = false; result.error("WG_STOP", "Отключение не подтверждено", null) }
            }
        }
    }
    fun closeForTest() { worker.shutdownNow() }
}

object WgSession {
    private var controller: WgController? = null
    var sink: EventChannel.EventSink? = null
        set(value) { field = value; controller?.sink = value }
    val state: String get() = controller?.state ?: "disconnected"
    fun get(context: Context): WgController = controller ?: WgController(context.applicationContext).also {
        it.sink = sink; controller = it
    }
}

class WgBridge(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var profile: String? = null
    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "stage" -> result.success(WgSession.state)
                "stop" -> WgSession.get(activity).stop(result)
                "start" -> {
                    if (pending != null) { result.error("BUSY", "Ожидается разрешение VPN", null); return }
                    val text = call.argument<String>("profile")
                    if (text == null || text.toByteArray(Charsets.UTF_8).size > 131072) {
                        result.error("PROFILE", "Некорректный профиль", null); return
                    }
                    val permission = VpnService.prepare(activity)
                    if (permission == null) WgSession.get(activity).connect(text, result)
                    else { pending = result; profile = text; activity.startActivityForResult(permission, 41) }
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            pending = null; profile = null
            result.error("VPN_PERMISSION", "Android не разрешил запуск VPN. Проверьте настройки другого VPN.", null)
        }
    }
    fun permissionResult(code: Int) {
        val result = pending ?: return
        val text = profile ?: return
        pending = null; profile = null
        if (code == Activity.RESULT_OK) WgSession.get(activity).connect(text, result)
        else result.error("DENIED", "Разрешение VPN отклонено", null)
    }
    fun detach() {
        pending?.error("CANCELLED", "Запрос разрешения прерван. Повторите подключение.", null)
        pending = null; profile = null
    }
}
