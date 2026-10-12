package dev.amirzr.flutter_v2ray_client.v2ray.core;

import android.content.Context;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** The VPN daemon writes; the UI reads from disk, never process-local statics. */
public final class QuietSocketDiagnostics {
    private static AtomicFile file;
    private static long ok, failed;
    public static File path(Context context) {
        return new File(context.getNoBackupFilesDir(), "xray-protection.txt");
    }
    public static synchronized void start(Context context) {
        file = new AtomicFile(path(context));
        ok = 0; failed = 0;
        save();
    }
    public static synchronized void record(boolean success) {
        if (success) ok++; else failed++;
        save();
    }
    private static void save() {
        if (file == null) return;
        FileOutputStream stream = null;
        try {
            stream = file.startWrite();
            stream.write((ok + " " + failed).getBytes(StandardCharsets.US_ASCII));
            file.finishWrite(stream);
        } catch (Exception ignored) {
            if (stream != null) file.failWrite(stream);
        }
    }
    public static long[] read(Context context) {
        try {
            String[] fields = new String(new AtomicFile(path(context)).readFully(),
                StandardCharsets.US_ASCII).trim().split(" ");
            if (fields.length != 2) return null;
            long good = Long.parseLong(fields[0]), bad = Long.parseLong(fields[1]);
            return good < 0 || bad < 0 ? null : new long[] {good, bad};
        } catch (Exception ignored) { return null; }
    }
}
