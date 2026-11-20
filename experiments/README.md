# ShinySlack Channel Probe - Phase 1

Goal: prove that a real incoming Slack notification exposes enough local context
to identify the source conversation before ShinySlack attempts per-channel sound routing.

This probe is intentionally read-only with respect to Slack data and ShinySlack sound routing.

## What it records

Only:

- timestamp
- encoded Slack team/workspace ID
- encoded Slack channel/conversation ID

It does **not** intentionally collect or write message text.

## Important security behavior

The probe temporarily launches Slack with Chromium/Electron remote debugging bound to
`127.0.0.1`. Do not make this a permanent Slack launch configuration.

When testing is finished:

1. Press Ctrl+C in the probe window.
2. Close Slack normally.
3. Start Slack normally again.

That removes the temporary debug mode.

## Run

Slack must be closed first. The probe deliberately refuses to kill a running Slack session.

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\experiments\SlackChannelProbe.ps1
```

When you see `READY`, generate real Slack notifications from channels you can identify.

Expected success output:

```text
NOTIFICATION team=T... channel=C... eventTs=...
```

The experiment passes when notifications from known different channels produce distinct
channel IDs consistently.

Logs are written to:

```text
%LOCALAPPDATA%\ShinySlack\channel-probe.log
```

## Phase 1 success criterion

Receive a real notification from a known channel and capture the correct/stable channel ID.
Do not implement sound routing until this is proven.
