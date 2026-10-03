"""Build pinned upstream OpenVPN for Android as an unminified headless AAR.
Upstream GPLv2 + additional terms: see doc/LICENSE.txt in the pinned source.
"""
from pathlib import Path
import subprocess, shutil, re, json
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]
SHA = 'b13ce20f68208747b7a79d339fce80c5e3656eef'
SRC = ROOT/'build/openvpn-source'
def run(args): subprocess.run(args, cwd=SRC, check=True)
SRC.parent.mkdir(parents=True, exist_ok=True)
if not (SRC/'.git').exists():
    subprocess.run(['git','clone','--no-checkout','https://github.com/schwabe/ics-openvpn.git',str(SRC)], check=True)
run(['git','checkout','--detach',SHA])
run(['git','submodule','update','--init','--recursive'])
# Use the same AGP generation as the embedding Flutter app, preserving upstream
# native code and submodule revisions. No upstream release APK is repackaged.
(SRC/'settings.gradle.kts').write_text('''pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
include(":main")
''')
(SRC/'build.gradle.kts').write_text('''plugins {
 id("com.android.library") version "8.13.0" apply false
 id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}
''')
(SRC/'gradle/wrapper/gradle-wrapper.properties').write_text('distributionUrl=https\\://services.gradle.org/distributions/gradle-8.13-bin.zip\n')
(SRC/'gradle.properties').write_text('android.useAndroidX=true\norg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8\n')
original = (SRC/'main/build.gradle.kts').read_text()
swig = original[original.index('var swigcmd'):original.index('dependencies {')]
(SRC/'main/build.gradle.kts').write_text('''import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskProvider
plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
 namespace = "de.blinkt.openvpn"
 compileSdk = 37
 ndkVersion = "30.0.14904198"
 buildFeatures { aidl = true; buildConfig = true }
 defaultConfig {
  minSdk = 26
  buildConfigField("String", "VERSION_NAME", "\\"0.7.66-quiet-source\\"")
  buildConfigField("int", "VERSION_CODE", "221")
  buildConfigField("String", "APPLICATION_ID", "\\"app.quietvpn.quiet_vpn\\"")
  ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
 }
 externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }
 sourceSets { getByName("main") { assets.srcDirs("src/main/assets", "build/ovpnassets") }; create("skeleton") }
 flavorDimensions += listOf("implementation", "ovpnimpl")
 productFlavors {
  create("skeleton") { dimension = "implementation" }
  create("ovpn2") { dimension = "ovpnimpl"; buildConfigField("boolean", "openvpn3", "false") }
 }
 buildTypes { getByName("release") { isMinifyEnabled = false } }
 compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
 kotlinOptions { jvmTarget = "17"; freeCompilerArgs += "-opt-in=kotlin.io.encoding.ExperimentalEncodingApi" }
 packaging { jniLibs { useLegacyPackaging = true } }
}
''' + swig + '''
dependencies {
 implementation("androidx.annotation:annotation:1.9.1")
 implementation("androidx.core:core-ktx:1.13.1")
}
''')
# Keep only internal components. No external API, boot receiver, or permission
# activities from the standalone upstream app are exported by this library.
a = '{http://schemas.android.com/apk/res/android}'
manifest = SRC/'main/src/main/AndroidManifest.xml'
tree = ET.parse(manifest); doc = tree.getroot(); app = doc.find('application')
app.attrib.clear()
allowed = {'.core.OpenVPNService', '.core.OpenVPNStatusService', '.core.keepVPNAlive', '.activities.DisconnectVPN', '.LaunchVPN'}
for e in list(app):
    if e.get(a+'name') not in allowed: app.remove(e); continue
    e.attrib.pop(a+'process', None)
    e.set(a+'exported', 'false')
    if e.tag == 'activity':
        for f in e.findall('intent-filter'): e.remove(f)
for e in list(doc):
    if e.tag == 'uses-permission' and e.get(a+'name') in {
        'android.permission.QUERY_ALL_PACKAGES','android.permission.RECEIVE_BOOT_COMPLETED','android.permission.READ_EXTERNAL_STORAGE'}:
        doc.remove(e)
ET.register_namespace('android', a[1:-1]); ET.register_namespace('tools','http://schemas.android.com/tools')
tree.write(manifest, encoding='utf-8', xml_declaration=True)
skeleton_manifest = SRC/'main/src/skeleton/AndroidManifest.xml'
skeleton_manifest.write_text(skeleton_manifest.read_text().replace('android:exported="true"', 'android:exported="false"'))
# Android skeleton can use in-process profiles; do not persist decrypted keys.
p = SRC/'main/src/main/java/de/blinkt/openvpn/core/ProfileManager.java'
s = p.read_text()
start = s.index('public static void setTemporaryProfile(')
end = s.index('\n    }', start)
block = s[start:end]
print('Temporary profile upstream implementation:', block)
# Upstream writes the temporary profile to disk for separate process recovery.
# This embedding runs in-process and stores the source encrypted on the Dart side.
block = re.sub(r'\s*saveProfile\(c, tmp\);', '', block)
s = s[:start] + block + s[end:]
p.write_text(s)
run(['bash','gradlew',':main:assembleSkeletonOvpn2Release','--no-daemon','--max-workers=2'])
out = ROOT/'android/app/libs'; out.mkdir(parents=True, exist_ok=True)
shutil.copyfile(SRC/'main/build/outputs/aar/main-skeleton-ovpn2-release.aar',out/'openvpn-core.aar')
provenance = {'upstream':SHA, 'submodules':subprocess.check_output(['git','submodule','status','--recursive'],cwd=SRC,text=True)}
(out/'openvpn-provenance.json').write_text(json.dumps(provenance, indent=2))
licenses = ROOT/'android/app/src/main/assets/licenses/openvpn'
licenses.mkdir(parents=True, exist_ok=True)
shutil.copyfile(SRC/'doc/LICENSE.txt', licenses/'LICENSE.txt')
(licenses/'SOURCE.txt').write_text('https://github.com/schwabe/ics-openvpn/tree/' + SHA + '\nEmbedding build and changes: https://github.com/BIKPOB/-/blob/main/tools/build_openvpn.py\n')
print('Built pinned OpenVPN source', SHA)
