# WireGuard / AmneziaWG embedding, 0.5.2

The Android application embeds the pinned official AmneziaWG tunnel library.
Plain WireGuard profiles use the same engine with masking parameters absent.
The profile importer now preserves the newer fields supported by this pinned
engine, including HeaderProtectionKey. It does not convert subscription keys
or silently strip unknown protocol settings.

## Lifecycle changes

- Parse configurations before loading JNI or opening a tunnel.
- Catch native linkage failures and ordinary backend exceptions at the worker
  boundary; report sanitized errors without profile contents or private keys.
- Serialize backend operations and deliver status on Android's main thread.
- Confirm connected only on the backend handshake callback; the ViewModel still
  requires its subsequent HTTPS check. Ignore handshake callbacks from a stopped
  session. A failed stop is not reported as disconnected.
- Clean up failed startup and allow retry when cleanup succeeds.
- Cancel pending permission requests when their Flutter Activity detaches.
- Start the upstream VPN service as a foreground service, with a notification
  and specialUse declaration. Do not restart it without an in-memory profile.

The source patch is in tools/build_awg.py. The upstream commit remains
ff15093bf3856fea0947923474870b86efb682f0; the binary cache is versioned for this patch.

## Checks and their scope

WgSessionTest uses the real native-library Java configuration parser and a
controlled backend adapter for handshake/error/stop scenarios. It also creates
the actual patched Android service notification under Robolectric API 34.
It does not exercise a real TUN device, JNI handshake, public server, network
handover, Doze, or DNS/IPv6 leak protection. No real-device tunnel success is
claimed without those tests and a valid server configuration.

## Where configurations come from

Quiet VPN does not possess a pool of authorized WireGuard/AmneziaWG accounts.
The public VPN Gate catalog supplies OpenVPN profiles only.

- Proton VPN documents downloading WireGuard configurations from the user's
  account: https://protonvpn.com/support/wireguard-configurations
- Amnezia documents exporting a self-hosted server's .conf for its native client:
  https://docs.amnezia.org/documentation/instructions/use-amneziawg-app/
- Amnezia Free creation is documented inside AmneziaVPN; this is not an anonymous
  public configuration catalog integrated into Quiet VPN:
  https://docs.amnezia.org/documentation/instructions/connect-amfree/

Do not commit private client keys to the repository or distribute one user's
configuration as a shared public server catalog. The UI links to these sources;
configuration issuance and account authentication remain provider-managed.
