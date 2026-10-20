# 0.10.8

Use the fresh baseline target consistently on both platforms, including LTE below 5 Mbit/s. Keep the 5 Mbit/s fallback only when a baseline is unavailable.

Prioritize untried tunnel candidates ahead of unsuccessful proxy screens, retaining failed screens as a final fallback. Reuse one catalog snapshot across rounds within a single search to avoid repeated downloads.

Android candidate startup reports an exception class in its error code without exporting configuration or credentials. This improves diagnosis; it does not claim to fix the unresolved native startup failure or mobile server reachability.
