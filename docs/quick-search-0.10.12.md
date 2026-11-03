# 0.10.12: bounded quick search

Quick selection has a shared 15-second search budget (including catalog and startup), uses local validated snapshots/bundled profiles, and skips baseline refresh, policy download, TCP preflight, and separate proxy lab. Final tunnel internet/speed checks remain mandatory on shipped engines. Deep comparison keeps its broader checks and eight-profile rounds.

At deadline the selection is invalidated and engine stop is requested. Late catalog/startup continuations must not start another tunnel. The UI reports failure at the deadline; reuse is blocked until the old work and native stop finish. Native cleanup or OS permission dialogs can take additional time. This is a bounded search, not a guarantee of a working public server in 15 seconds.

The separate current-connection report screen, toolbar button, native probe and share channel from 0.10.11 are removed. Background diagnostics and existing diagnostic-log copying remain.
