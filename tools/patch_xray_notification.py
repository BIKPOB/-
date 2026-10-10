"""Apply a checked, idempotent notification patch to the pinned Flutter dependency."""
import json
from pathlib import Path
from urllib.parse import urlparse, unquote
root = Path(__file__).resolve().parents[1]
config = root / '.dart_tool/package_config.json'
package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'flutter_v2ray_client')
uri = urlparse(package['rootUri'])
base = Path(unquote(uri.path)) if uri.scheme == 'file' else (config.parent / unquote(package['rootUri'])).resolve()
p = base / 'android/src/main/java/dev/amirzr/flutter_v2ray_client/v2ray/core/V2rayCoreManager.java'
s = p.read_text()
if '// Quiet VPN speed notification' in s:
    print('Xray notification patch already applied')
    raise SystemExit(0)
def replace(old, new):
    global s
    assert s.count(old) == 1, f'Pinned Xray source changed: {old[:80]}'
    s = s.replace(old, new)
replace('    private void makeDurationTimer(', '''    // Quiet VPN speed notification
    private NotificationCompat.Builder quietNotification;
    private long quietLastTick;
    private static String quietRate(long bytes) {
        if (bytes >= 1048576) return String.format(java.util.Locale.ROOT, "%.1f МиБ/с", bytes / 1048576.0);
        if (bytes >= 1024) return String.format(java.util.Locale.ROOT, "%.1f КиБ/с", bytes / 1024.0);
        return bytes + " Б/с";
    }
    private void quietUpdateNotification(Context context) {
        if (quietNotification == null || V2RAY_STATE != AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) return;
        try {
            String text = "↓ " + quietRate(downloadSpeed) + "   ↑ " + quietRate(uploadSpeed);
            quietNotification.setContentText(text).setSubText("Текущий трафик VPN");
            ((NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE))
                .notify(NOTIFICATION_ID, quietNotification.build());
        } catch (Exception ignored) { }
    }
    private void makeDurationTimer(''')
replace('''                    downloadSpeed = delta[0];
                    uploadSpeed = delta[1];
                    totalDownload = totalDownload + downloadSpeed;
                    totalUpload = totalUpload + uploadSpeed;''', '''                    long now = android.os.SystemClock.elapsedRealtime();
                    long elapsed = now - quietLastTick;
                    totalDownload += delta[0];
                    totalUpload += delta[1];
                    downloadSpeed = quietLastTick > 0 && elapsed > 0 ? (long) (delta[0] * 1000.0 / elapsed) : 0;
                    uploadSpeed = quietLastTick > 0 && elapsed > 0 ? (long) (delta[1] * 1000.0 / elapsed) : 0;
                    quietLastTick = now;
                    quietUpdateNotification(context);''')
replace('    public void stopCore() {', '    public void stopCore() {\n        quietNotification = null; quietLastTick = 0;')
replace('    public boolean startCore(final V2rayConfig v2rayConfig, int tunFd) {', '    public boolean startCore(final V2rayConfig v2rayConfig, int tunFd) {\n        quietNotification = null; quietLastTick = 0;')
replace('''            context.startForeground(NOTIFICATION_ID, notificationBuilder.build());''','''            notificationBuilder.setContentText("↓ —   ↑ —");
            quietNotification = notificationBuilder;
            context.startForeground(NOTIFICATION_ID, notificationBuilder.build());''')
# The upstream action incorrectly opened the activity instead of using stopIntent.
replace('.addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, notificationContentPendingIntent)',
        '.addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, pendingIntent)')
replace('NotificationManager.IMPORTANCE_DEFAULT);', 'NotificationManager.IMPORTANCE_LOW);')
p.write_text(s)
print('Patched pinned Xray speed notification')
