package app.quietvpn.quiet_vpn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin

class MainActivity : FlutterActivity() {
    @Deprecated("Required by the OpenVPN plugin permission contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 24) {
            OpenVPNFlutterPlugin.connectWhileGranted(resultCode == RESULT_OK)
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
