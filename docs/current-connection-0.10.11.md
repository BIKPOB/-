# Android current-connection report

Open the network-test icon in the top bar while Quiet is disconnected and selection is idle. Select a label, run, inspect, share or copy. Repeat with Turbo enabled (Quiet must not be excluded by Turbo). The test never starts Quiet's VPN or changes bypass settings.

Native requests use ConnectivityManager.activeNetwork.openConnection: no BaseNetwork selection, protect(), process binding, or persisted VPN selection baseline. Pause native baseline measurements and UI probes while the page is open. Requests verify the default network before/after measurements. HTTPS uses normal certificate validation, no redirects, bounded reads, 6-second connect/read deadlines, 75-second overall checks. Cancel closes the current connection. A short sample includes setup latency and is not line capacity. Upload is not tested. Export is plain text through Android Sharesheet, with explicit exit-IP disclosure. No credentials, raw logs, SSID or device IDs are included.

Cloudflare trace supplies the observed exit address; three 1 MiB downloads use speed.cloudflare.com. HTTPS checks also include gstatic and ya.ru. Endpoint failures do not identify censorship or packet-loss rates. The Android VPN flag is app-specific and does not prove the provider identity. Real Turbo/LTE comparison requires device testing.
