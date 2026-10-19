# Deep selection 0.10.5

The CandidateHost path replaced the initial eight-entry plan with usable proxy
results, or exactly one WireGuard profile when no proxy passed. The generic
source/protocol two-failure cutoff also suppressed remaining deep attempts.

Deep selection now builds a deduplicated queue of up to eight configurations:
verified proxies first, then ranked candidates, including unconfirmed proxies
and WireGuard. Screening failures are not proof that a native tunnel cannot work.
The two-failure source cutoff remains exclusive to quick selection. A separate
640-second tunnel-stage budget prevents the proxy stage from consuming the time
reserved for eight connection attempts (up to 70 seconds each plus teardown).

The queue can contain fewer than eight entries if fewer distinct profiles exist.
User cancellation, physical network changes, local route/teardown failures and a
confirmed suitable live tunnel still stop selection early. Eight means distinct
candidate attempts, not eight retries of one server. Existing per-network rotation
and live-tunnel verification remain in place. Diagnostic output includes screening
pool/result/success counts, queue size, and tunnel-stage budget exhaustion.

Regression coverage: zero/one usable proxy, WireGuard-only queue, duplicate
profiles, a short catalog, quick-mode behavior, and eight same-source failures.
Real endpoint availability and Samsung/Android 16 behavior require device testing.
