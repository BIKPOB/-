#!/usr/bin/env python3
"""Generate official Flutter platform runners, then apply owned Android files."""
import pathlib
import argparse
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--platforms', default='android,windows', choices=['android', 'windows', 'android,windows'])
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
if 'android' in args.platforms:
    template = ROOT/'platform_templates/android'
    target = ROOT/'android/app/src/main'
    shutil.copyfile(template/'AndroidManifest.xml', target/'AndroidManifest.xml')
    kotlin = target/'kotlin/app/quietvpn/quiet_vpn'
    kotlin.mkdir(parents=True, exist_ok=True)
    for source in template.glob('*.kt'):
        shutil.copyfile(source, kotlin/source.name)
    build = ROOT/'android/app/build.gradle.kts'
    text = build.read_text()
    text = text.replace('compileSdk = flutter.compileSdkVersion', 'compileSdk = 36')
    text = text.replace('ndkVersion = flutter.ndkVersion', 'ndkVersion = "27.0.12077973"')
    text = text.replace('minSdk = flutter.minSdkVersion', 'minSdk = 26')
    text = text.replace('targetSdk = flutter.targetSdkVersion', 'targetSdk = 35')
    text = text.replace('android {', 'android {\n    packaging { jniLibs { useLegacyPackaging = true } }', 1)
    text += '\ndependencies {\n    implementation(files("libs/amneziawg-tunnel.aar"))\n    implementation(files("libs/openvpn-core.aar"))\n    implementation("androidx.core:core-ktx:1.13.1")\n    implementation("androidx.collection:collection:1.4.0")\n    implementation("androidx.annotation:annotation:1.9.1")\n}\n'
    text = text.replace('defaultConfig {', 'defaultConfig {\n        ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }', 1)
    text = text.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("debug")\n            isMinifyEnabled = false\n            isShrinkResources = false')
    build.write_text(text)
    settings = ROOT/'android/settings.gradle.kts'
    import re
    settings.write_text(re.sub(r'(id\("com.android.application"\) version )"[^"]+"', r'\1"8.13.0"', settings.read_text()))
    wrapper = ROOT/'android/gradle/wrapper/gradle-wrapper.properties'
    wrapper.write_text(re.sub(r'gradle-[0-9.]+-(?:all|bin)\.zip', 'gradle-8.13-all.zip', wrapper.read_text()))
    root_build = ROOT/'android/build.gradle.kts'
    text = root_build.read_text()
    if 'jitpack.io' not in text:
        text = text.replace('mavenCentral()', 'mavenCentral()\n        maven { url = uri("https://jitpack.io") }')
    text = """subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdk = 36
            }
        }
    }
}
""" + text
    root_build.write_text(text)
# Set the UAC level through the linker so its generated manifest agrees.
if 'windows' in args.platforms:
    runner_cmake = ROOT/'windows/runner/CMakeLists.txt'
    text = runner_cmake.read_text()
    text += "\ntarget_link_options(${BINARY_NAME} PRIVATE \"/MANIFESTUAC:level='requireAdministrator' uiAccess='false'\")\n"
    runner_cmake.write_text(text)
default_test = ROOT/'test/widget_test.dart'
if default_test.exists():
    default_test.unlink()
subprocess.run([flutter, 'pub', 'get'], cwd=ROOT, check=True)
print('Platform runners created. Run flutter analyze && flutter test.')
