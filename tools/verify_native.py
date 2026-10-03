"""Fail packaging if legacy crypto survives the engine migration."""
import json, re, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    versions = {}
    for abi in ('arm64-v8a', 'armeabi-v7a'):
        for lib in ('libopenvpn.so', 'libovpnexec.so', 'libovpnutil.so'):
            assert f'lib/{abi}/{lib}' in z.namelist(), (abi, lib)
        data = z.read(f'lib/{abi}/libopenvpn.so')
        ssl = sorted(set(x.decode() for x in re.findall(rb'OpenSSL [0-9][ -~]{0,70}', data)))
        assert any(x.startswith(('OpenSSL 3.', 'OpenSSL 4.')) for x in ssl), ssl
        versions[abi] = ssl
    for name in z.namelist():
        if name.endswith('.so'):
            assert b'OpenSSL 1.1.' not in z.read(name), f'Legacy OpenSSL in {name}'
    assert 'assets/licenses/openvpn/LICENSE.txt' in z.namelist()
print(json.dumps(versions, indent=2))
