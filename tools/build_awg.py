"""Build the pinned official AmneziaWG Android tunnel from source, including submodules."""
from pathlib import Path
import subprocess,shutil,os
root=Path(__file__).resolve().parents[1]
sha='ff15093bf3856fea0947923474870b86efb682f0'
vendor=root/'build/awg-source'
def run(args,cwd=None):subprocess.run(args,cwd=cwd,check=True)
if not (vendor/'.git').exists():
 vendor.parent.mkdir(parents=True,exist_ok=True)
 run(['git','clone','--no-checkout','https://github.com/amnezia-vpn/amneziawg-android.git',str(vendor)])
run(['git','checkout','--detach',sha],vendor)
run(['git','submodule','update','--init','--recursive'],vendor)
settings=vendor/'settings.gradle.kts'
settings.write_text(settings.read_text().replace('include(":ui")',''))
# Keep the embedded VPN alive under modern Android background limits.
backend=vendor/'tunnel/src/main/java/org/amnezia/awg/backend/GoBackend.java'
text=backend.read_text()
old='context.startService(new Intent(context, VpnService.class));'
assert old in text
text=text.replace(old, 'if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(new Intent(context, VpnService.class)); else ' + old)
needle='            vpnService.complete(this);\n            if (intent == null'
assert needle in text
text=text.replace(needle, '''            android.app.NotificationManager notifications = getSystemService(android.app.NotificationManager.class);
            String channel = "quietvpn_wg";
            notifications.createNotificationChannel(new android.app.NotificationChannel(channel,
                "Quiet VPN", android.app.NotificationManager.IMPORTANCE_LOW));
            android.app.Notification.Builder notification = new android.app.Notification.Builder(this, channel)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("Quiet VPN")
                .setContentText("WireGuard / AmneziaWG")
                .setOngoing(true);
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (launch != null) notification.setContentIntent(android.app.PendingIntent.getActivity(this,
                52, launch, android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT));
            startForeground(5252, notification.build());
            vpnService.complete(this);
            if (intent == null''')
text=text.replace('return super.onStartCommand(intent, flags, startId);', 'return START_NOT_STICKY;')
backend.write_text(text)
# Build the library only, preserving official namespace and pinned submodules.
run(['bash','gradlew',':tunnel:assembleRelease','--no-daemon'],vendor)
out=root/'android/app/libs';out.mkdir(parents=True,exist_ok=True)
shutil.copyfile(vendor/'tunnel/build/outputs/aar/tunnel-release.aar',out/'amneziawg-tunnel.aar')
print('Built official AmneziaWG tunnel at',sha)
