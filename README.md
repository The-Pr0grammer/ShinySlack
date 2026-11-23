# ShinySlack

**Your Slack. Your sound. Your alerts.**

**Current Windows release: v2.7.11.** Previous v2.7.5 installers remain archived under their original release tag.

In v2.7.11, HTML Deck V10.4 is the primary floating deck, supervised by a heartbeat watchdog; the native WinForms deck remains an automatic fallback. The installer includes the WebView2 host and the production bridge.

ShinySlack is a local-first Windows companion for Slack Desktop. It adds custom notification sounds, per-channel routing, a persistent visual alert deck, native Slack deep links, and a live Activity feed without sending your notification data to a ShinySlack server.

> **Beta:** ShinySlack is unofficial and not affiliated with Slack or Salesforce. Use it only where your device and workplace policy allow it.

## Install and run

For normal users, the supported install path is the Windows installer.

1. Open the [ShinySlack landing page](https://the-pr0grammer.github.io/ShinySlack/).
2. Download `ShinySlackSetup.exe` from the latest published release.
3. Run the installer. It installs per-user to `%LOCALAPPDATA%\ShinySlack`; admin rights are not required by default.
4. Leave **Open ShinySlack now** checked when setup finishes.
5. ShinySlack opens its local dashboard in your browser and starts the notification router + floating alert deck.

### Opening ShinySlack later

Double-click the **ShinySlack** shortcut on your Desktop or in the Start menu.

That shortcut is the front door to the app. It:

- starts the notification router if needed;
- starts the persistent alert deck if needed;
- starts the local dashboard backend; and
- opens the dashboard in your default browser.

You do **not** need to run PowerShell scripts manually after installation.

If Windows shows an unknown-publisher or SmartScreen warning while the beta is unsigned, confirm that the installer came from this repository's GitHub Release and verify the published SHA-256 before continuing.

## First setup

Once the dashboard opens:

1. Choose a built-in preset or your own MP3 as the default notification sound.
2. Optionally assign different sounds to individual Slack channels.
3. Keep Slack Desktop's **built-in Slack notifications** enabled.
4. Send or receive a real notification and confirm audio, the floating alert deck, and Activity all react.

ShinySlack's live detector follows Slack's own desktop notification windows across monitors and screen positions. It does **not** read notifications from Windows Action Center.

## What ShinySlack does today

- Custom default notification sound.
- Per-channel notification sounds.
- Built-in mastered sound preset library.
- Universal ShinySlack volume control.
- Persistent visual alert deck with four-corner resizing, double-click minimize/restore, an accessible compact volume control with red muted warning, animated accent-glow title, up/down expansion, three growth modes, and hover help.
- Native deep links back into Slack Desktop for linked channels.
- Low-latency live Activity feed.
- Local sound-ownership safety/fallback controls.
- Windows Startup persistence for the router and alert deck.
- Local browser dashboard on loopback only.

Offline notification-history recovery while the PC is asleep/off is still under development and is not claimed as part of the current stable privacy baseline.

## Privacy

The privacy baseline established in v2.7.5 and hardened in v2.7.6 continues to be enforced:

- The dashboard server binds to Windows loopback only.
- Dashboard API authentication uses a cryptographically generated per-process token.
- Live notification message text is not persisted; accessible text is reduced to a SHA-256 fingerprint for short-lived duplicate suppression.
- Channel/team identifiers remain local runtime data and are excluded from Git.
- Slack token patterns and local identifiers are checked by the repository privacy audit.
- Current live routing does not require Slack credentials.
- Custom sound files remain local unless they are intentionally included in the public preset library.

See [docs/FAQ.md](docs/FAQ.md) for the detailed **Is my privacy protected?** audit answer and threat model.

## Supported notification source

ShinySlack currently detects **Slack Desktop's built-in notification windows** using Windows UI Automation.

- Works regardless of where the Slack notification appears on screen.
- Works across multiple monitors.
- Does not rely on a bottom-right screen coordinate.
- Does not consume Windows Action Center notifications.

If your Slack notifications are configured to go only through Windows Action Center instead of Slack's built-in notification UI, the live ShinySlack detector will not see them.

## Deck volume and mute safety

Router audio volume is shared between the dashboard and deck. The compact deck keeps a visible red warning when muted or at 20% or lower. In Router-owned audio mode, ShinySlack restores audible volume after both user interfaces have been inactive for approximately 90 seconds. Native Fallback mode remains unchanged. The deck has four-corner resize, header double-click minimize/restore, and a title glow cycling through alert accents.

## Installer behavior

The installer:

- installs to `%LOCALAPPDATA%\ShinySlack`;
- creates a branded **ShinySlack** Desktop shortcut by default;
- creates a branded **ShinySlack** Start-menu shortcut;
- launches ShinySlack after installation unless you uncheck that option; and
- leaves background notification routing available after the dashboard tab is closed.

The installed Desktop/Start shortcuts launch `Start-ShinySlack.ps1` in a hidden PowerShell window. `Start-ShinySlack.cmd` remains available as the visible diagnostic launcher for technicians when startup troubleshooting is needed.

`Install-ShinySlack.ps1` remains an internal/manual maintenance path for development and legacy cache work. Fresh users should use `ShinySlackSetup.exe`.

## Repository layout

- `app/` - installed Windows application and runtime.
- `installer/` - Inno Setup installer definition.
- `docs/` - GitHub Pages landing page.
- `.github/workflows/release.yml` - validates and builds `ShinySlackSetup.exe`.
- `.github/workflows/pages.yml` - deploys the public landing page.
- `tools/Privacy-Audit.ps1` - privacy release gate.

## Upgrade guarantee

Every newly published ShinySlack installer must include a user-initiated **Check for Updates** path that locates a real newer Windows installer, provides direct download and SHA-256 links, explains the in-place upgrade steps, preserves existing user settings, and falls back to the official Releases page if discovery fails. Updates must **never** auto-run without consent. The release workflow enforces these capabilities with `tools/Update-Contract.ps1`; see [UPDATE_POLICY.md](UPDATE_POLICY.md) for the required Windows upgrade smoke tests.

## Release flow

Release tags must point at `main` HEAD and match `app/version.txt`. A tagged release triggers the Windows build workflow, which:

1. validates bundled PowerShell;
2. validates the install/run contract;
3. builds `ShinySlackSetup.exe`;
4. generates `ShinySlackSetup.exe.sha256`; and
5. publishes both files to the GitHub Release.

The landing page and dashboard update checker use published GitHub Release metadata. The landing page links to the newest release with a real ShinySlackSetup.exe asset; the dashboard compares its installed version with the latest published version.

## Attribution

The project was informed by public reverse-engineering work around Slack notification sound caching, including `SharonBrizinov/slack-sounds`. ShinySlack's Windows implementation, router, visual deck, and local dashboard are separate work.

## License

No open-source license has been selected yet. Public visibility does not by itself grant reuse rights.
