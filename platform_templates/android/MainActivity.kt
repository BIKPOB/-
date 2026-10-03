package app.quietvpn.quiet_vpn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin

class MainActivity : FlutterActivity() {
    private lateinit var wg: WgBridge
    override fun configureFlutterEngine(engine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(engine)
        wg = WgBridge(this)
        io.flutter.plugin.common.MethodChannel(engine.dartExecutor.binaryMessenger, "quietvpn/wg").setMethodCallHandler(wg::handle)
        io.flutter.plugin.common.EventChannel(engine.dartExecutor.binaryMessenger, "quietvpn/wg-events").setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: io.flutter.plugin.common.EventChannel.EventSink?) { WgSession.sink = sink; sink?.success(WgSession.state) }
            override fun onCancel(args: Any?) { WgSession.sink = null }
        })
    }
    @Deprecated("Required by the OpenVPN plugin permission contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 41) wg.permissionResult(resultCode)
        if (requestCode == 24) {
            OpenVPNFlutterPlugin.connectWhileGranted(resultCode == RESULT_OK)
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
