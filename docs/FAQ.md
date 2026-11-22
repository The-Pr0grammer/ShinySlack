# ShinySlack FAQ

## Is my privacy protected?

**ShinySlack v2.7.6 is designed to keep Slack notification data local, and the v2.7.6 privacy audit passes before the release can be committed.**

The live Router uses Windows UI Automation to identify Slack's built-in notification surface. It needs the Slack channel label for routing. Slack's accessibility tree can also expose notification message text. In v2.7.6, ShinySlack reads that text only long enough to compute a SHA-256 deduplication fingerprint. The raw message string is not written to the Router log, Activity, configuration, the notification deck, or Git. ShinySlack does not intentionally parse or persist a sender/author field.

Some metadata is intentionally stored locally because the product needs it. `%LOCALAPPDATA%\ShinySlack` can contain channel route names, local sound paths, linked Slack team/channel IDs used for native deep links, visual-alert settings, and Router event logs containing channel/sound/backend metadata. Those files are runtime state, not source code.

ShinySlack's dashboard binds to Windows loopback only (`127.0.0.1` / localhost), not the LAN. Dashboard API calls use a fresh cryptographically generated per-process token. ShinySlack does not include telemetry.

The app can contact GitHub to check published ShinySlack release metadata. That update request does not include Slack channel data, message bodies, sender data, or local configuration.

Notification-history recovery is **disabled in v2.7.6**. The dashboard does not accept a Slack API token, and the history worker exits immediately. History will return only after the v2.8 privacy, retention, and consent model is explicitly designed.

Git is guarded in three layers:

1. Private runtime filenames and directories are excluded by `.gitignore`.
2. The repository uses a pre-commit privacy audit that blocks known runtime-state files and Slack-style token patterns.
3. The v2.7.6 audit compares the real channel names, team IDs, and channel IDs in the local `channel-routes.json` against tracked repository content. The release commit is blocked if a local identifier is found.

**v2.7.6 audit outcome: PASS is required for commit.** The hardening release is not committed if any of the checks above fail.

This is not a sandbox against malware or another process already running as the same Windows user. A malicious same-user process could potentially inspect local files or process memory. ShinySlack's privacy controls are intended to prevent accidental persistence, network exposure, and Git/source-control leakage of Slack notification data.

## What if I leave ShinySlack muted?

Router mode shares volume between the dashboard and the floating deck. The speaker icon stays visible in compact mode and turns red if audio is muted or at or below 20%. If both the dashboard and deck are closed or inactive for approximately 90 seconds, ShinySlack restores audible volume to reduce missed notifications. This safeguard does not change NativeFallback mode. The dashboard displays the same behavior beneath the mute control.

## Does ShinySlack store message bodies?

No. In v2.7.6, accessible notification text may be read transiently to calculate a SHA-256 deduplication fingerprint. Only the hash is retained briefly in memory for duplicate suppression. Raw message text is not persisted.

## Does ShinySlack know who sent a message?

ShinySlack v2.7.6 does not intentionally extract or store a sender/author field. Slack controls the accessibility strings exposed by its desktop notification UI, so the Router treats accessible message text as opaque input and hashes it immediately.

## Are my Slack channel names or IDs uploaded to GitHub?

No application feature uploads them to GitHub. Channel routing and deep-link metadata live under `%LOCALAPPDATA%\ShinySlack`.

The v2.7.6 Git privacy audit also checks the real local channel names, team IDs, and channel IDs against tracked repository files and fails the release commit if one is found.

## What data does ShinySlack keep locally?

Depending on enabled features, local runtime state can include:

- channel names used for routing;
- selected/default sound paths;
- Slack team/channel IDs for user-configured native deep links;
- Router event metadata such as channel, sound, backend, and timestamp;
- visual-alert settings and window position;
- sound-ownership/failsafe state;
- generated WAV cache files and custom/preset audio.

These are stored under `%LOCALAPPDATA%\ShinySlack` and are excluded from Git source control.

## Does ShinySlack send telemetry?

No. v2.7.6 has no ShinySlack telemetry service.

The dashboard can make a GitHub API request when checking for ShinySlack updates. That request retrieves public release information and does not send Slack data.

## Does v2.7.6 access Slack message history?

No. Offline/history recovery is intentionally disabled in v2.7.6.

The v2.8 goal is to recover supported notification/activity history after the laptop was asleep or powered off, but that work will not proceed until its privacy model defines exactly what is fetched, what is stored, retention, consent, and deletion behavior.

## Does ShinySlack support Windows Notification Center / Action Center?

No. Engine V17 detects **Slack's built-in desktop notifications** using Slack-owned Windows accessibility elements. Those notifications can be detected anywhere on any connected monitor.

Windows Notification Center / Action Center is a separate notification surface and is not supported in v2.7.6.

## Why does ShinySlack need the channel name?

The channel name is the routing key that lets ShinySlack choose a channel-specific sound and display the matching visual alert. It is stored locally in ShinySlack runtime configuration and event metadata.

## What protects Git commits from private runtime data?

The repo ships a privacy audit under `tools/Privacy-Audit.ps1` and configures `.githooks/pre-commit` as the active Git hook path for this development checkout.

The hook rejects commits containing known ShinySlack runtime-state files or Slack-style token patterns. The full audit additionally checks local Slack channel/team identifiers against tracked files.
## What did the v2.7.5 privacy audit find?

The audit found one concrete privacy issue in earlier development and release history: a real Slack channel ID had been reused as an example value in the native deep-link UI and backend validation text.

A Slack channel ID is metadata, not an authentication credential, but ShinySlack treats real workspace identifiers as private runtime data. The value was removed from current source and purged from every reachable affected branch/tag before the v2.7.5 privacy baseline was committed.

Because v2.7.0 had been built from an affected tag, its static installer/checksum release assets and matching GitHub Actions build artifact were withdrawn after the rewritten tag was successfully pushed. Source archives follow the rewritten tag.

The audit did not find a Slack OAuth token or a persisted notification message body in tracked source. v2.7.5 also changed live duplicate detection so accessible message text is immediately converted to a SHA-256 fingerprint instead of being retained as raw dedupe state.

The release gate now checks both current tracked content and reachable branch/tag history for the local Slack team/channel IDs known to this installation.

Previously cloned Git history or previously downloaded v2.7.0 binaries are outside ShinySlack's control and cannot be remotely erased. The pre-purge local Git bundle retained by the developer also intentionally contains the old history and should be treated as sensitive rollback material.
