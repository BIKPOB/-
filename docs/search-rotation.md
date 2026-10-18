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

This does not increase speed-test budgets, change measurement methods or verify
performance in Russia. Those remain separate issues. Exhausted/small catalogs,
expiry and the comparison candidate can legitimately produce repeated servers.

Validation: `dart tools/test_search_rotation.dart` covers advancement beyond
24 entries, separate networks, restored storage, partial groups, catalog additions,
expiry and bounded network history. Standalone analyzer passed for the rotation
module and test. Full Flutter analysis/platform tests were not run in this change.
