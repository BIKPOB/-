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
                } else if (call.method == "resolveEndpoint") {
                    val host = call.argument<String>("host") ?: ""
                    probeWorker.execute {
                        try {
                            val addresses = java.net.InetAddress.getAllByName(host)
                            val address = addresses.firstOrNull { it is java.net.Inet4Address } ?: addresses.first()
                            runOnUiThread { result.success(address.hostAddress) }
                        } catch (_: Exception) { runOnUiThread { result.error("dns", "DNS: адрес VPN-сервера не найден", null) } }
                    }
                } else if (call.method == "prepareDiagnostics") {
                    result.success(XrayDiagnostics.prepare(applicationContext))
                } else if (call.method == "tunnelProbe") {
                    probeWorker.execute {
                        val measured = TunnelProbe.measure(applicationContext)
                        runOnUiThread { result.success(measured) }
                    }
                } else if (call.method == "probe") {
                    probeWorker.execute {
                        val delay = ProxyProbe.measure(applicationContext).toMutableMap()
                        delay["detail"] = "${delay["detail"]}\n${XrayDiagnostics.report(applicationContext)}"
                        runOnUiThread { result.success(delay) }
                    }
                } else if (call.method == "cancelProbe") { ProxyProbe.cancel(); XrayDiagnostics.stop(); result.success(null) }
                else result.notImplemented()
            }
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/catalog-cache")
            .setMethodCallHandler { call, result ->
                if (call.method == "network") {
                    val manager = getSystemService(android.net.ConnectivityManager::class.java)
                    val networks = manager.allNetworks.mapNotNull { manager.getNetworkCapabilities(it) }
                        .filter { it.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                            !it.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) }
                    result.success(when {
                        networks.any { it.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) } -> "wifi"
                        networks.any { it.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) } -> "mobile"
                        networks.isNotEmpty() -> "other"
                        else -> "offline"
                    })
                    return@setMethodCallHandler
                }
                val source = call.argument<String>("source")
                if (source == null || !CatalogCache.sources.containsKey(source)) {
                    result.error("source", "Неизвестная подписка", null)
                } else try {
                    when (call.method) {
                        "read" -> result.success(CatalogCache.read(applicationContext, source))
                        "save" -> {
                            CatalogCache.save(applicationContext, source, call.argument<String>("text") ?: "", true)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("cache", "Кэш недоступен", null) }
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
