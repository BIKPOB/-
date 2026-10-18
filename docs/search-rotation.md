# Per-network candidate rotation

Source-only change after 0.10.1; no APK/EXE release.

The shortlist now prioritizes candidates not attempted on the current network,
then older attempts. Ordering is applied before the per-protocol shortlist cap
and again before the candidate lab cap, so repeated runs can reach later entries.
One locally measured candidate above the speed target may occupy the last slot
as a comparison/fallback; it is not assumed to remain fast.

The lab records each group immediately before address resolution, not the whole
planned queue. Cancellation leaves groups never reached available next time.
Attempt history is scheduling metadata, not a failed-server training label.
Profiles and network identifiers are hashed. The existing local network-lab
store persists up to 4096 entries per network, 8 networks, with a 7-day expiry.
Catalog refresh retains history for unchanged profiles and admits new profiles.

Follow-up: a fast search compares up to two qualifying candidates and deep
search up to three, subject to the existing deadline. Failed downloads can yield
unused rounds to later candidates (up to 6/12 speed-test attempts). The total
number of requested download samples stays at the old 3/6 candidates multiplied
by rounds, preserving the maximum requested payload budget. This does not change
measurement methods or verify performance in Russia. Exhausted/small catalogs,
expiry and the comparison candidate can legitimately produce repeated servers.

Validation: `dart tools/test_search_rotation.dart` covers advancement beyond
24 entries, separate networks, restored storage, partial groups, catalog additions,
expiry and bounded network history. Standalone analyzer passed for the rotation
module and test. The candidate-lab integration suite also passed: cancellation preserves unstarted
groups, later candidates are reached after three failed downloads, comparison
counts and the transfer budget hold. Existing real-loopback stalled CONNECT/TLS,
route-change, sequential-speed and cleanup regressions passed. Targeted Dart
analysis passed; full Flutter analysis/platform tests were not run.
