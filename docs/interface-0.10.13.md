# Quiet VPN 0.10.13 — Figma interface

Source: Figma IByPptb32Dorj2KzgOVGKC, page 0:1. SVGs exported directly from original nodes because temporary MCP asset links returned HTML. Icon and Android bitmap derivatives are rendered from these SVGs, not screenshots. Bahnschrift variable font supplied by the user; Light (300), Bold (700), SemiCondensed width 87.5.

Flutter motion: 420 ms ease-out slide/fade for panels, animated settings expansion, state crossfades. Reduced motion uses zero duration for primary transitions. Connection progress is indeterminate because native engines do not publish a reliable percentage. Startup waits for initialization and never holds a fake timer.

Main: stopwatch for the current connected session, data rates, power, AI, server menu, information. Stopwatch excludes trial connections during AI selection and resets after disconnect. Process restarts reset the stopwatch. Full diagnostics and bypass settings remain in Information; learning and quick/deep selection live in AI settings.

Android home-screen widget uses a 2:1 composition. Buttons bring the app to the foreground before invoking an action (system VPN permissions and existing foreground-only selection remain respected). Snapshot refreshed at most every five seconds by Flutter, and on native health checks / launcher refresh. Old snapshots are labelled for verification rather than treated as current traffic. Widget is not an independent background VPN controller.

Windows tray click opens compact controls; context menu opens the main UI or disconnects and exits. Closing hides only if tray setup succeeded; otherwise it minimizes to keep the UI recoverable. Reserve continues in the existing desktop engine.

Device checks still needed: Samsung launcher placement/resizing, permission dialogs from widget, tray placement with multiple monitors and DPI scaling, animations on physical devices. CI cannot establish public-server reliability in the user's mobile network.
