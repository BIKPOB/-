#!/usr/bin/env python3
"""Generate official Flutter platform runners, then apply owned Android files."""
import pathlib
import argparse
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--platforms', default='android,windows', choices=['android', 'android,windows'])
args = parser.parse_args()
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('Install Flutter 3.32.8 and put flutter on PATH first.')
# flutter create can rewrite lib/main.dart/pubspec; preserve authored sources.
protected = {ROOT/name: (ROOT/name).read_bytes() for name in
             ['pubspec.yaml', 'lib/main.dart', 'README.md', 'analysis_options.yaml', '.gitignore']}
try:
    subprocess.run([flutter, 'create', f'--platforms={args.platforms}', '--org',
                    'app.quietvpn', '--project-name', 'quiet_vpn', '--no-pub', str(ROOT)], check=True)
finally:
    for path, content in protected.items():
        path.write_bytes(content)
template = ROOT/'platform_templates/android'
target = ROOT/'android/app/src/main'
shutil.copyfile(template/'AndroidManifest.xml', target/'AndroidManifest.xml')
kotlin = target/'kotlin/app/quietvpn/quiet_vpn'
kotlin.mkdir(parents=True, exist_ok=True)
shutil.copyfile(template/'MainActivity.kt', kotlin/'MainActivity.kt')
build = ROOT/'android/app/build.gradle.kts'
text = build.read_text()
text = text.replace('minSdk = flutter.minSdkVersion', 'minSdk = 26')
text = text.replace('targetSdk = flutter.targetSdkVersion', 'targetSdk = 35')
text = text.replace('android {', 'android {\n    packaging { jniLibs { useLegacyPackaging = true } }', 1)
build.write_text(text)
root_build = ROOT/'android/build.gradle.kts'
text = root_build.read_text()
if 'jitpack.io' not in text:
    text = text.replace('mavenCentral()', 'mavenCentral()\n        maven { url = uri("https://jitpack.io") }')
root_build.write_text(text)
# Windows UI needs service/driver privileges for this local-process adapter.
manifest = ROOT/'windows/runner/runner.exe.manifest'
if 'windows' in args.platforms:
    text = manifest.read_text()
    if 'requestedExecutionLevel' not in text:
        text = text.replace('</assembly>', '''<trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
  <security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
  </requestedPrivileges></security>
</trustInfo></assembly>''')
    manifest.write_text(text)
default_test = ROOT/'test/widget_test.dart'
if default_test.exists():
    default_test.unlink()
subprocess.run([flutter, 'pub', 'get'], cwd=ROOT, check=True)
print('Platform runners created. Run flutter analyze && flutter test.')
