# Windows site bypass

Explicit opt-in domain and IP exceptions for Xray VLESS/Shadowsocks. URLs normalize to their exact host (including www); paths are discarded, subdomains match. No automatic .ru-wide rule. Default traffic and DNS remain proxied. HTTP/TLS/QUIC sniffing is route-only; hidden domains (ECH) can remain proxied. No TLS interception.

Saved settings apply to the next connection. Existing connections are not changed. WireGuard cannot enforce these rules: automatic selection excludes it and manual connection fails with an explanation while exceptions exist. Android retains its existing per-app exclusions; mobile reliability is unverified.

Validation: domain/IP parser and configuration tests, generated configs validated by pinned Xray, actual Xray routing smoke with a blocked default proxy.
