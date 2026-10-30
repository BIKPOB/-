# Quiet VPN 1.0.0

Source: Figma IByPptb32Dorj2KzgOVGKC, Page 2 (47:7), inspected 2026-10-30.
Menu 48:511, connecting 48:2034, connected 48:2189, servers 47:226.

Original exported SVG assets are bundled locally. Bahnschrift Light SemiCondensed
uses weight 300 and width 87.5; sizes adapt to device logical pixels.
Connecting glow rotates linearly through four 500 ms states; pause remains upright.
Power state changes use 500 ms ease-in, messages 300 ms slide/fade, settings use
animated size, panels slide from the bottom. Reduced-motion settings disable loops
and entry transitions. Loading follows the supplied 200 ms logo variants.

Main screen contains only chat and controls. Traffic and session duration are a
live message, rather than a new message each second. History is bounded to 100
messages and is not persisted. Search preparation, attempts, failures, cancellation,
and reconnect advice appear in the chat. Manual server/profile actions remain in
the server panel; learning remains in AI settings. Bypass uses the server panel's
green background and rounded white outlines. Diagnostics retains selectable text
and a copy action. Information retains baseline, health, reserve and reconnect actions.
The timer is additionally retained in Information although not drawn in Page 2.

Quick progress: elapsed whole seconds, 15 divisions. Deep progress: completed
VPN candidates divided by actual queue length, reset for each explicitly numbered
round. Preparation is indeterminate. Successful early completion does not pretend
that the remaining queue was tested. Reserve recovery does not reuse search progress.

The session clock belongs to the view model, not the screen. It measures wall time
without requiring UI ticks, survives foreground reconciliation, and resets on a real
stop or new tunnel. It does not claim continuity after process termination.
The target speed is capped at 1,000,000 bytes/second (8 Mbit/s); lower network targets
are preserved. Actual traffic is not throttled.

Android launcher widget and Windows compact widget panel removed. Normal Windows
tray open/exit remain. Notification small icons use a transparent monochrome Figma
asset in drawable resources at all five densities; launcher icons retain their color.

Physical Android/Windows use and mobile operator restrictions require device testing;
CI cannot establish long-term reliability of public VPN servers.
