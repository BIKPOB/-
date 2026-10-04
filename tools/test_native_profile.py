"""Check live VPN Gate profiles with the actual new Java parser, via Robolectric."""
from pathlib import Path
import base64, csv, io, subprocess, shutil
root = Path(__file__).resolve().parents[1]
source = (root/'build/live-catalog.csv').read_text(encoding='utf-8-sig')
rows = csv.DictReader(io.StringIO(source[source.index('#HostName,'):]))
profiles = []
for row in rows:
    if row.get('OpenVPN_ConfigData_Base64'):
        profiles.append(base64.b64decode(row['OpenVPN_ConfigData_Base64'], validate=True))
    if len(profiles) == 3: break
assert profiles, 'No live profiles to test'
resources = root/'android/app/src/test/resources'; resources.mkdir(parents=True, exist_ok=True)
for i, profile in enumerate(profiles): (resources/f'live-{i}.ovpn').write_bytes(profile)
target = root/'android/app/src/test/java/app/quietvpn/quiet_vpn'; target.mkdir(parents=True, exist_ok=True)
(target/'NativeProfileTest.java').write_text('''package app.quietvpn.quiet_vpn;
import java.io.*;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import de.blinkt.openvpn.core.ConfigParser;
import de.blinkt.openvpn.core.ProfileManager;
import de.blinkt.openvpn.VpnProfile;
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class NativeProfileTest {
 @Test public void liveProfilesRetainCredentialsAndPassNativeValidation() throws Exception {
  var context = RuntimeEnvironment.getApplication();
  ProfileManager.getInstance(context);
  for (int i = 0; i < COUNT; i++) {
   var stream = getClass().getResourceAsStream("/live-" + i + ".ovpn");
   assertNotNull(stream);
   var parser = new ConfigParser();
   try (var reader = new InputStreamReader(stream, java.nio.charset.StandardCharsets.UTF_8)) {
    parser.parseConfig(reader);
   }
   VpnProfile profile = parser.convertProfile();
   assertEquals(de.blinkt.openvpn.R.string.no_error_found, profile.checkProfile(context));
   assertTrue(VpnProfile.isEmbedded(profile.mCaFilename));
   assertTrue(VpnProfile.isEmbedded(profile.mClientKeyFilename));
   ProfileManager.setTemporaryProfile(context, profile);
   assertSame(profile, ProfileManager.get(context, profile.getUUIDString()));
   assertFalse(context.getFileStreamPath("temporary-vpn-profile.vp").exists());
   assertFalse(context.getFileStreamPath("temporary-vpn-profile.cp").exists());
  }
 }
}
'''.replace('COUNT',str(len(profiles))))
(target/'NativeStartupTest.java').write_text('''package app.quietvpn.quiet_vpn;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import de.blinkt.openvpn.core.*;
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34, application = QuietVpnApplication.class)
public class NativeStartupTest {
 @Test public void startupNotificationDoesNotCrash() throws Exception {
  var context = RuntimeEnvironment.getApplication();
  assertFalse(GlobalPreferences.getForceConnected());
  var manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
  manager.createNotificationChannel(new android.app.NotificationChannel(
    OpenVPNService.NOTIFICATION_CHANNEL_NEWSTATUS_ID, "Quiet VPN", NotificationManager.IMPORTANCE_LOW));
  var controller = Robolectric.buildService(OpenVPNService.class).create();
  try {
   var method = OpenVPNService.class.getDeclaredMethod("showNotification",
     String.class, String.class, String.class, long.class, ConnectionStatus.class, Intent.class);
   method.setAccessible(true);
   method.invoke(controller.get(), "Connecting", "Connecting",
     OpenVPNService.NOTIFICATION_CHANNEL_NEWSTATUS_ID, 0L, ConnectionStatus.LEVEL_START, null);
   assertEquals(1, manager.getActiveNotifications().length);
  } finally { controller.destroy(); }
 }
}
''')
for test in (root/'platform_templates/android_tests').glob('*.kt'):
    shutil.copyfile(test, target/test.name)
p = root/'android/app/build.gradle.kts'
s = p.read_text().replace('android {', 'android {\n    testOptions { unitTests.isIncludeAndroidResources = true }', 1)
s += '\ndependencies { testImplementation("junit:junit:4.13.2"); testImplementation("org.robolectric:robolectric:4.14.1") }\n'
p.write_text(s)
subprocess.run(['bash','gradlew',':app:testReleaseUnitTest','--no-daemon','--max-workers=2'],cwd=root/'android',check=True)
print('Live profiles validated with source-built Android OpenVPN parser; temporary profiles stay in memory.')
