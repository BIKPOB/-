from pathlib import Path
import shutil, subprocess
root = Path(__file__).resolve().parents[1]
target = root/'android/app/src/test/java/app/quietvpn/quiet_vpn'
target.mkdir(parents=True, exist_ok=True)
for test in (root/'platform_templates/android_tests').glob('*.kt'):
    shutil.copyfile(test, target/test.name)
p = root/'android/app/build.gradle.kts'
s = p.read_text().replace('android {', 'android {\n    testOptions { unitTests.isIncludeAndroidResources = true }', 1)
s += '\ndependencies { testImplementation("junit:junit:4.13.2"); testImplementation("org.robolectric:robolectric:4.14.1") }\n'
p.write_text(s)
subprocess.run(['bash','gradlew',':app:testReleaseUnitTest','--no-daemon','--max-workers=2'],cwd=root/'android',check=True)
