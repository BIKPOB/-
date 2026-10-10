package app.quietvpn.quiet_vpn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private var browserResult: io.flutter.plugin.common.MethodChannel.Result? = null
    private lateinit var wg: WgBridge
    private val probeWorker = java.util.concurrent.Executors.newSingleThreadExecutor()
    override fun configureFlutterEngine(engine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(engine)
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/diagnostics")
            .setMethodCallHandler { call, result ->
                if (call.method == "report") {
                    try { result.success(CrashDiagnostics.report(applicationContext)) }
                    catch (_: Exception) { result.error("diagnostics", "Диагностика недоступна", null) }
                } else result.notImplemented()
            }
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/config-browser")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") { result.notImplemented(); return@setMethodCallHandler }
                val source = call.argument<String>("source")
                if (source == null || !(ConfigBrowserPolicy.sources.containsKey(source) || source == "custom")) { result.error("source", "Неизвестный источник", null); return@setMethodCallHandler }
                if (browserResult != null) { result.error("busy", "Браузер уже открыт", null); return@setMethodCallHandler }
                browserResult = result
                try { startActivityForResult(Intent(this, ConfigBrowserActivity::class.java).putExtra("source", source).putExtra("url", call.argument<String>("url")), 77) }
                catch (_: Exception) { browserResult = null; result.error("browser", "Не удалось открыть браузер", null) }
            }
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/xray-state")
            .setMethodCallHandler { call, result ->
                if (call.method == "stage") {
                    val state = dev.amirzr.flutter_v2ray_client.v2ray.V2rayController.getConnectionState().name
                    result.success(state.removePrefix("V2RAY_"))
                } else if (call.method == "probe") {
                    probeWorker.execute {
                        val delay = ProxyProbe.measure()
                        runOnUiThread { result.success(delay) }
                    }
                } else if (call.method == "cancelProbe") { ProxyProbe.cancel(); result.success(null) }
                else result.notImplemented()
            }
        wg = WgBridge(this)
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/wg").setMethodCallHandler(wg::handle)
        io.flutter.plugin.common.EventChannel(engine.dartExecutor.binaryMessenger, "quietvpn/wg-events").setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: io.flutter.plugin.common.EventChannel.EventSink?) { WgSession.sink = sink; sink?.success(WgSession.state) }
            override fun onCancel(args: Any?) { WgSession.sink = null }
        })
    }
    override fun cleanUpFlutterEngine(engine: io.flutter.embedding.engine.FlutterEngine) {
        browserResult?.error("cancelled", "Окно приложения пересоздано. Откройте источник повторно.", null); browserResult = null
        if (::wg.isInitialized) wg.detach()
        WgSession.sink = null
        ProxyProbe.cancel(); probeWorker.shutdownNow()
        super.cleanUpFlutterEngine(engine)
    }
    @Deprecated("Activity permission result contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 77) {
            browserResult?.success(if (resultCode == RESULT_OK) data?.getStringExtra("profile") else null)
            browserResult = null
        }
        if (requestCode == 41) wg.permissionResult(resultCode)
        super.onActivityResult(requestCode, resultCode, data)
    }
}
