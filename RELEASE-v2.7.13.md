# ShinySlack v2.7.13

- ShinySlack HTML Deck V10.5 uses the native Windows frame by default for Snap Layouts.
- Theme-aware DWM caption colors keep the active and inactive title bar consistent.
- Removes the former 960x850 window cap and prevents automatic content sizing from overriding a snapped window.
- Packages the production V10.5 host source, executable, companion build files, current HTML/JS and a matching **installer** stage integrity manifest.
- Dashboard theme synchronization and Open Alert Deck restore are preserved from v2.7.12.

Validation: Windows Snap was exercised in an isolated preview and production host deployment was reported successful by the operator. A separate clean-Windows installer smoke test is still recommended. The installed runtime's existing ownership/promotion state is not modified by the release staging process.