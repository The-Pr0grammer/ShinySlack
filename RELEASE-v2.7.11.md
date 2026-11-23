# ShinySlack v2.7.11 â€” candidate release notes

- Promotes HTML Deck V10.4 as the primary Windows floating alert deck.
- Includes the WebView2 host and production supervisor inside the Windows installer payload.
- Uses supervised HTML heartbeat ownership with native WinForms fallback when HTML is unavailable or unhealthy.
- Preserves the native alert deck for fallback rather than removing it.
- Carries forward v2.7.9 routing, mute safety, persistent alerts, and dashboard behavior.

## Required verification before publishing

- Verify a clean-install scenario in a Windows VM or test profile, including WebView2 requirements.
- Verify default first launch enters `owner-active` with exactly one HTML host and monitor, and no native process.
- Verify a genuine HTML failure triggers native fallback, and a later normal launch restores HTML.
- Verify the HTML `Dismiss all` footer location and four themes after installation.
- Verify installed assets against the promotion manifest and run existing privacy, update, and release contracts.
- Confirm installer upgrades preserve user settings, sounds, routes, and startup tasks.
- Only then merge into main, tag v2.7.11 at main HEAD, and publish via the GitHub Actions workflow.