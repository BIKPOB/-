# Experimental prepared reserve

Opt-in per application run. VLESS/Shadowsocks only. Android runs checks while
its Flutter UI is foreground; no promise of suspended/background execution.

- Measure the current tunnel every two minutes, serially with reserve tests.
  Idle traffic counters are never treated as a bandwidth measurement.
- Three samples below 60% of the target, spanning at least two minutes, are
  required. A recovered sample clears the degradation streak.
- Compare a reserve outside the current TUN: Windows binds Xray sockets to
  the selected physical interface; Android binds candidate-core sockets to the
  selected underlying Network. Unsupported/ambiguous routes fail without switching.
- Reserve must have two successful speed samples, reach the target, improve the
  current sample by at least 50%, and be less than two minutes old.
- Prepare at most three profiles per batch. Search every ten minutes while
  healthy, or after repeated degradation. Old tunnel stays up during search.
- Stop old TUN only after a reserve qualifies. Activate and verify the new TUN;
  if it fails, attempt the previous profile once. Failed candidate gets a
  30-minute cooldown. Maximum two handovers/hour, at least ten minutes apart.
- Payload reservations: at most 24 MiB/hour on metered/unknown-cost links and
  96 MiB/hour on unmetered links, plus protocol overhead/catalog traffic. Failed
  probes count too. Exhausting the budget preserves the current tunnel.
- Manual disconnect, network change and cancellation invalidate pending results.

This is prevalidated failover, not TCP-session migration. IP changes and TUN
restart can interrupt existing streams. The UI reports total handover/verification
time, not a measured packet-loss interval. Reconnection can still fail even if
proxy testing passed. WireGuard and service-specific YouTube/ChatGPT checks are
not included. The normal automatic selection path remains separate.

Validation includes policy budget/cooldown tests, view-model failover/rollback
and manual-cancel tests, and a Windows smoke test where unbound HTTPS fails
through a blackhole TUN while an interface-bound reserve proxy succeeds.
Android physical-route behavior still requires a real-device check; Robolectric
does not execute the native proxy core.
