"""Validate the APK structure, Android metadata and cryptographic signature."""
import os
from pathlib import Path
import subprocess
import sys
import zipfile

apk = Path(sys.argv[1]).resolve()
with zipfile.ZipFile(apk) as archive:
    assert archive.testzip() is None
    names = archive.namelist()
    assert 'AndroidManifest.xml' in names and 'classes.dex' in names
    assert 'lib/arm64-v8a/libflutter.so' in names
    assert 'lib/armeabi-v7a/libflutter.so' in names
sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
build_tools = sorted((sdk/'build-tools').iterdir(), reverse=True)
directory = next(p for p in build_tools if (p/'apksigner').is_file() and (p/'aapt').is_file())
signature = subprocess.check_output([str(directory/'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)], text=True)
metadata = subprocess.check_output([str(directory/'aapt'), 'dump', 'badging', str(apk)], text=True)
assert "package: name='app.quietvpn.quiet_vpn'" in metadata
assert "sdkVersion:'26'" in metadata
(apk.parent/'APK_VALIDATION.txt').write_text(signature + '\n' + metadata)
print('APK archive, ARM ABIs, package ID, minimum SDK and signature validated.')
