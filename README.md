# ShinySlack

**Your Slack. Your sound.**

ShinySlack is an unofficial Windows utility that lets you replace Slack's `Knock Brush` notification sound with your own MP3. The UI runs locally in your browser; the patching engine operates only on local Slack/cache files.

> **Beta:** tested on the standard Slack desktop install for Windows. Slack or Chromium cache changes may require updates. Use only where your device/workplace policy allows it.

## 20-second user guide

1. Download `ShinySlackSetup.exe` from the latest release.
2. Install and open ShinySlack.
3. In Slack, select **Knock Brush** and receive **one real notification**.
4. Drop an MP3 into ShinySlack and click **Apply Sound**.
5. Test with another real Slack notification.

Healthy dashboard: `Slack: Running` · `Cache: Present` · `Sound: Custom configured` · `Watcher: Watching`.

## How it works

ShinySlack discovers Slack's current Knock Brush asset/cache entry, verifies cache payloads with SHA-256 before writing, safely patches while Slack is closed for controlled repairs, and maintains a watcher for cache rebuilds. The watcher does not routinely force-close a running Slack session.

If a custom MP3 is larger than Slack's available cached sound slot, ShinySlack can use `ffmpeg` to compress it. Install FFmpeg with:

```powershell
winget install --id Gyan.FFmpeg -e
```

## Repository layout

- `app/` — local ShinySlack Windows app
- `installer/` — Inno Setup installer definition
- `docs/` — GitHub Pages landing page
- `.github/workflows/release.yml` — builds `ShinySlackSetup.exe` and publishes tagged releases
- `.github/workflows/pages.yml` — deploys the landing page

## Publish your first beta

1. Create a public GitHub repo named `ShinySlack`.
2. Upload/commit this repository.
3. In **Settings → Pages**, set the source to **GitHub Actions**.
4. Push the repo to `main`. The Pages workflow deploys the landing page.
5. Create/push a release tag:

```bash
git tag v0.1.0-beta
git push origin v0.1.0-beta
```

The Windows workflow builds the installer and creates a GitHub Release containing:

- `ShinySlackSetup.exe`
- `ShinySlackSetup.exe.sha256`

The landing page Download button always targets:

```text
/releases/latest/download/ShinySlackSetup.exe
```

so it automatically follows future releases.

## Installer behavior

The installer is per-user by default and installs to:

```text
%LOCALAPPDATA%\ShinySlack
```

It creates Start Menu/Desktop shortcuts and launches ShinySlack after installation. First sound selection/configuration still happens inside the ShinySlack UI.

## Security / privacy

v2.7.5 establishes a privacy-hardened local baseline:

- UI server binds to Windows loopback only.
- Dashboard API authentication uses a cryptographically generated per-process token.
- Live notification message text is not persisted; accessible text is hashed immediately for short-lived duplicate suppression.
- Channel/deep-link metadata is local runtime state and is excluded from Git.
- Notification-history/API-token features are disabled in v2.7.5 pending the v2.8 privacy design.
- A repository privacy audit and pre-commit gate protect against accidental runtime-state/token commits.
- Custom MP3s stay local unless intentionally added to the packaged preset library.
- Cache writes require known stock/custom hashes; unfamiliar cache state fails closed.
- ShinySlack is unofficial and not affiliated with Slack or Salesforce.

See [docs/FAQ.md](docs/FAQ.md) for the detailed **"Is my privacy protected?"** audit answer and current threat model.
## Attribution

The project was informed by public reverse-engineering work around Slack notification sound caching, including `SharonBrizinov/slack-sounds`. ShinySlack's Windows implementation and local web UI are separate work.

## License

No open-source license has been selected yet. Public visibility does not by itself grant reuse rights. Choose a license before encouraging external forks/contributions.

## One-command GitHub publish helper

If GitHub CLI is installed and authenticated, the included helper can create/push the repo, enable Pages, and push the first beta tag:

```powershell
powershell -ExecutionPolicy Bypass -File .\Publish-ShinySlack.ps1
```

See `PUBLISH_IN_5_MINUTES.md` for the microwave version.

## v2 beta channel routing

v2 beta adds local real-time Slack notification audio routing on Windows.

- Default notification MP3 for unmapped Slack notifications.
- Per-channel MP3 routes.
- Channel-first UI Automation detection for low-latency playback.
- Duplicate/fallback suppression.
- Hidden background router with Windows Startup persistence.
- Bundled `app/silent-slack.mp3` for muting Slack's native base sound.
- Existing global cache watcher remains in place as the silent-base keeper.

For the cleanest v2 setup, apply `silent-slack.mp3` using the original ShinySlack sound control, then choose an audible DEFAULT sound under Channel Sounds. The router will own the audible notification while Slack's patched base remains silent.

Low-latency WAV caching uses FFmpeg when available. Without FFmpeg, v2 beta falls back to MP3 playback instead of dropping the notification.

This is still beta software. Slack UI/accessibility changes may require router updates.
