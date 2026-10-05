package app.quietvpn.quiet_vpn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private var browserResult: io.flutter.plugin.common.MethodChannel.Result? = null
    private lateinit var ovpn: OpenVpnBridge
    private lateinit var wg: WgBridge
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
                if (source == null || !ConfigBrowserPolicy.sources.containsKey(source)) { result.error("source", "Неизвестный источник", null); return@setMethodCallHandler }
                if (browserResult != null) { result.error("busy", "Браузер уже открыт", null); return@setMethodCallHandler }
                browserResult = result
                try { startActivityForResult(Intent(this, ConfigBrowserActivity::class.java).putExtra("source", source), 77) }
                catch (_: Exception) { browserResult = null; result.error("browser", "Не удалось открыть браузер", null) }
            }
        ovpn = OpenVpnBridge(this)
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/openvpn").setMethodCallHandler(ovpn::handle)
        io.flutter.plugin.common.EventChannel(engine.dartExecutor.binaryMessenger, "quietvpn/openvpn-events").setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: io.flutter.plugin.common.EventChannel.EventSink?) { OpenVpnSession.sink = sink; sink?.success(OpenVpnSession.state) }
            override fun onCancel(args: Any?) { OpenVpnSession.sink = null }
        })
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
        if (::ovpn.isInitialized) ovpn.detach()
        WgSession.sink = null
        OpenVpnSession.sink = null
        super.cleanUpFlutterEngine(engine)
    }
    @Deprecated("Required by the OpenVPN plugin permission contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 77) {
            browserResult?.success(if (resultCode == RESULT_OK) data?.getStringExtra("profile") else null)
            browserResult = null
        }
        if (requestCode == 41) wg.permissionResult(resultCode)
        if (requestCode == 24) {
            ovpn.permissionResult(resultCode)
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
