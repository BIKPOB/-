# OpenVPN source migration (0.5.0)

The former `openvpn_flutter` dependency pulled in an old prebuilt Android
engine containing OpenSSL 1.1.1l. It is removed from pubspec and replaced by
an in-process MethodChannel/EventChannel adapter and an AAR built from
`schwabe/ics-openvpn` commit `b13ce20f68208747b7a79d339fce80c5e3656eef`.

Reproduction: run `python tools/bootstrap.py --platforms android`, then
`python tools/build_awg.py` and `python tools/build_openvpn.py`, followed by
`flutter build apk --release --target-platform android-arm64,android-arm`.
Build tooling: Java 17, compile SDK 36 (target 35, min 26), OpenVPN NDK
30.0.14904198, AGP/Gradle 8.13. The Flutter application uses NDK 27.0.12077973.
The GitHub Android workflow prepares Java, SDK licenses and SWIG and records
source revisions and native-library version markers with the artifact.

## Embedding changes

- Build the skeleton OpenVPN 2 variant as a library, with all submodule
  revisions pinned by the upstream commit. The OpenSSL source is 4.0.3.
- Disable shrinking/obfuscation in the library and application. Upstream's
  v0.7.66 release warns that its optimization broke profile loading; that
  release APK is not used here.
- Remove standalone app branding and the external control API, boot receiver
  and exported helper activities. Retained helpers are not exported.
- Run the VPN service in the application's process so status and temporary
  profiles are shared. Temporary profiles are not additionally serialized
  to disk by ProfileManager; the application's imported source profiles
  remain in its existing secure storage.
- Create notification channels before starting the native foreground service.
- Keep the native session separate from Activity instances. Connected is
  reported from the engine, not merely from granting the VPN permission.

The application still needs real-device checks for tunnel operation, network
changes, competing VPNs, background execution and DNS/IPv6 leaks. The source
migration and an antivirus result alone do not establish production readiness.

## Source and license notices

OpenVPN for Android: GPL v2 with upstream additional terms and linking
exceptions; https://github.com/schwabe/ics-openvpn/blob/b13ce20f68208747b7a79d339fce80c5e3656eef/doc/LICENSE.txt

The APK includes that notice and the source/build links under
`assets/licenses/openvpn/`. The exact embedding changes are in
`tools/build_openvpn.py` in this repository. All transitive source revisions
are recorded in `openvpn-provenance.json` alongside the APK. Third-party
components retain their respective licenses.

## Startup correction in 0.5.1

The embedding previously omitted GlobalPreferences initialization from the
standalone upstream Application. OpenVPNService reads getForceConnected() when
constructing its startup notification, which throws when the singleton is unset.
QuietVpnApplication now initializes the preferences before any service is created.
A Robolectric regression test constructs the actual service notification to cover
this path; the previous parser-only test did not exercise service startup.
This corrects an identified crash path. A device crash trace is still needed if
the reported failure persists; a notification test is not a real tunnel test.
