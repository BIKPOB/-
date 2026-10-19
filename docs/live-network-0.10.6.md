# Live network selection and Android health monitoring

- The manual network-analysis button is removed. The existing idle observer checks
  connection identity every 30 seconds, reuses DNS/HTTPS analysis for at most five
  minutes (two on unmetered networks), and automatically refreshes it. Selection
  accepts analysis no older than 30 seconds. Analyses include the live session;
  saved results from another session cannot qualify as current measurements.
- Direct throughput expires after five minutes. Selection can request a fresh
  sample with a 30-second retry guard while retaining the 8/32 MiB daily payload
  limits. Background throughput sampling retains its conservative interval.
- Deep candidates need three samples above target and minimum/maximum >= 0.65
  to qualify as a stable measured candidate. This is a short test, not a long-term
  guarantee. Unqualified working candidates may remain explicitly labeled reserves.
- Android uses a native scheduled worker in the running VPN foreground-service
  process. It binds probes to the watched VPN Network, never the physical route.
  Two consecutive failed cycles, each trying two HTTPS targets, prompt recovery.
  Two successful cycles clear a connectivity warning. Every five minutes it also
  tests 256 KiB, approximately 3 MiB/hour plus protocol overhead. Two slow samples
  prompt recovery; idle traffic counters are never treated as a speed measurement.
- The notification opens the app. The user chooses reconnect or deep selection of
  another server. An intentional disconnect clears the warning; an unexpected
  disconnect preserves it. Warning text survives process recreation locally.
- Native monitoring does not depend on Flutter foreground timers. Android Doze,
  force-stop, process termination and notification permission can still delay or
  prevent checks/alerts; there is no promise of uninterrupted monitoring after
  the VPN service/process has been killed. Device validation remains necessary.
