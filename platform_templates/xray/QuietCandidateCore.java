package dev.amirzr.flutter_v2ray_client.v2ray.core;

import android.content.Context;
import android.net.Network;
import android.os.ParcelFileDescriptor;
import org.json.JSONArray;
import org.json.JSONObject;
import libv2ray.CoreCallbackHandler;
import libv2ray.CoreController;
import libv2ray.Libv2ray;
import libv2ray.V2RayProtector;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities;

/** UI-process proxy-only core; independent from the VPN service process. */
public final class QuietCandidateCore {
    private static CoreController controller;
    public static synchronized void start(Context context, Network network, String config) throws Exception {
        stop();
        validate(config);
        Libv2ray.initCoreEnv(Utilities.getUserAssetsPath(context), "");
        Libv2ray.useProtector(new V2RayProtector() {
            @Override public boolean protect(long fd) {
                // Duplicate only the descriptor; never take ownership of Go's fd.
                try (ParcelFileDescriptor duplicate = ParcelFileDescriptor.fromFd((int) fd)) {
                    network.bindSocket(duplicate.getFileDescriptor());
                    return true;
                } catch (Exception e) { return false; }
            }
        });
        CoreController next = Libv2ray.newCoreController(new CoreCallbackHandler() {
            @Override public long onEmitStatus(long status, String message) { return 0; }
            @Override public long startup() { return 0; }
            @Override public long shutdown() { return 0; }
        });
        controller = next;
        try { next.startLoop(config, 0); }
        catch (Exception e) { stop(); throw new IllegalStateException("Candidate core rejected configuration"); }
    }
    public static void validate(String config) throws Exception {
        if (config.length() > 131072) throw new IllegalArgumentException("Config too large");
        JSONObject root = new JSONObject(config);
        JSONArray inbounds = root.getJSONArray("inbounds");
        if (inbounds.length() < 1 || inbounds.length() > 3) throw new IllegalArgumentException("Inbound count");
        for (int i = 0; i < inbounds.length(); i++) {
            JSONObject in = inbounds.getJSONObject(i);
            int port = in.getInt("port");
            if (!"127.0.0.1".equals(in.getString("listen")) ||
                !"http".equals(in.getString("protocol")) || port < 1024 || port > 65535)
                throw new IllegalArgumentException("Only loopback HTTP proxy is allowed");
        }
    }
    public static synchronized void stop() {
        CoreController old = controller;
        controller = null;
        if (old != null) { try { old.stopLoop(); } catch (Exception ignored) { } }
    }
}
