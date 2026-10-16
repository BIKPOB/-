"""Fix pinned dependency routing without changing its upstream files in git."""
import json
import shutil
from foreground_patch import patch_xray
from pathlib import Path
from urllib.parse import urlparse, unquote
root = Path(__file__).resolve().parents[1]
config = root / '.dart_tool/package_config.json'
package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'flutter_v2ray_client')
uri = urlparse(package['rootUri'])
base = Path(unquote(uri.path)) if uri.scheme == 'file' else (config.parent / unquote(package['rootUri'])).resolve()
java = base / 'android/src/main/java/dev/amirzr/flutter_v2ray_client/v2ray'
shutil.copyfile(root/'platform_templates/xray/QuietSocketDiagnostics.java', java/'core/QuietSocketDiagnostics.java')
p = java/'utils/Utilities.java'
s = p.read_text()
if '// Quiet VPN owns DNS routing' not in s:
    start = s.index('            boolean hasDnsRule = false;')
    end = s.index('            return json.toString();', start)
    s = s[:start] + '            // Quiet VPN owns DNS routing; never inject missing direct outbound.\n\n' + s[end:]
    p.write_text(s)
p = java/'services/V2rayVPNService.java'
s = patch_xray(p.read_text()).replace('private static final int VPN_MTU = 1500;', 'private static final int VPN_MTU = 1280;')
s = s.replace('builder.addDisallowedApplication(getPackageName());', '// Quiet VPN must traverse TUN for end-to-end checks; core sockets use protect().')
p.write_text(s)
p = java/'core/V2rayCoreManager.java'
s = p.read_text().replace('Utilities.ensureTunInbound(config, 1500)', 'Utilities.ensureTunInbound(config, 1280)')
if 'quietProtectOk' not in s:
    s = s.replace('    public void setUpListener(Service targetService) {', '''    public static long quietProtectOk = 0, quietProtectFailed = 0;
    public void setUpListener(Service targetService) {
        quietProtectOk = 0; quietProtectFailed = 0;''')
    old = '                        return v2rayServicesListener.onProtect((int) fd);'
    assert s.count(old) == 1
    s = s.replace(old, '''                        boolean ok = v2rayServicesListener.onProtect((int) fd);
                        if (ok) quietProtectOk++; else quietProtectFailed++;
                        return ok;''')
    s = s.replace('''                    return true;
                }
            });''', '''                    quietProtectFailed++;
                    return false;
                }
            });''', 1)
p.write_text(s)
# Static fields in the UI are unrelated to the :RunSoLibV2RayDaemon fields.
if 'QuietSocketDiagnostics.start' not in s:
    s = s.replace('quietProtectOk = 0; quietProtectFailed = 0;',
        'quietProtectOk = 0; quietProtectFailed = 0;\n        QuietSocketDiagnostics.start(targetService);')
    s = s.replace('if (ok) quietProtectOk++; else quietProtectFailed++;',
        'if (ok) quietProtectOk++; else quietProtectFailed++;\n                        QuietSocketDiagnostics.record(ok);')
    s = s.replace('                    quietProtectFailed++;',
        '                    QuietSocketDiagnostics.record(false);\n                    quietProtectFailed++;')
    p.write_text(s)
assert 'QuietSocketDiagnostics.start(targetService)' in s
assert 'QuietSocketDiagnostics.record(ok)' in s
print('Patched DNS routing, TUN MTU and cross-process socket diagnostics')
