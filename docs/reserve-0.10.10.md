# Reserve recovery 0.10.10

Previously explicit engine disconnect/error only stopped the tunnel. Recovery can now activate an already prepared reserve from the same physical network, at most ten minutes old. Full tunnel and speed confirmation are required again; failure stops the tunnel and prompts for new selection. The old failed server is not blindly retried on hard drop. Existing slow-link handover retains its rollback behavior.

Windows retains reserve preparation while minimized; Android Dart recovery is foreground-only. Native Android health notifications remain available separately. First preparation starts after five seconds rather than two minutes. Stale reserve measurements are labelled as stale. Two automatic switch attempts per hour, at least thirty seconds apart for hard drops; slow-link switches retain ten-minute cooldown.

Regression coverage: explicit error/disconnected events while desktop is hidden, changed physical network, manual cancellation during activation, slow failed reserve, age and rate limits. Real mobile carrier reachability and seamless preservation of existing TCP connections are not guaranteed.

Per-domain multiple proxy selection is not implemented by this release; Windows direct-site exceptions remain available.
