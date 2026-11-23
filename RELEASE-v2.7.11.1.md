# ShinySlack v2.7.11.1 - dashboard theme and deck-launch hotfix

- Restore dashboard selection for Shiny, Retro, Arcade and Ghost Type themes.
- Persist the dashboard theme to the existing local visual-theme.json, consumed by the HTML Deck V10.4 host.
- Route dashboard Open Alert Deck requests through the HTML ownership launcher rather than directly starting WinForms.
- Correct update-version comparison to support four numeric components, including v2.7.11.1.
- Preserve HTML-first startup, native fallback, Activity rendering, audio routing and the Dismiss all footer.

Validation still needed: automated contract checks, Windows installer build and silent install, browser theme selection and HTML deck sync, active-owner/fallback behavior and upgrade preservation.