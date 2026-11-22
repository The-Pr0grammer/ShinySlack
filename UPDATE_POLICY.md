# ShinySlack Upgrade Guarantee

**Release requirement:** Every new public ShinySlack installer must allow someone running that version to discover a later published release and complete a safe upgrade without guessing what to download.

## User-visible update flow

1. **Check for Updates** reads release metadata from the official GitHub repository. Compare the installed application version with the latest published release **that actually includes `ShinySlackSetup.exe`**. Ignore drafts and releases missing the installer.
2. When a newer version is available, display **Download vX.Y.Z Installer**, the installed and available versions, a direct installer link, the published SHA-256 checksum link, and release notes.
3. Clearly instruct the user to download the installer, close the dashboard tab, run `ShinySlackSetup.exe` over their existing installation **without uninstalling first**, then reopen ShinySlack and verify the version, notification sounds, channel routes, and alert deck.
4. **Never auto-execute an installer.** Do not silently elevate privileges, run an unattended update, erase user configuration, or restart Slack just for update discovery.
5. **Fallback if GitHub is unavailable:** retain the current working installation; show a useful error and an official [GitHub Releases](https://github.com/The-Pr0grammer/ShinySlack/releases) link. If an installer asset is temporarily unavailable, do not call the update installed or claim success.

## Preserve existing user settings

An in-place upgrade must retain `%LOCALAPPDATA%\ShinySlack` runtime state, especially `channel-routes.json`, user-selected/default sounds, native Slack deep-link associations, local alert preferences, and applicable user presets. Keep a consistent Inno Setup AppId and per-user install directory. Never ask the user to uninstall first as a prerequisite to upgrading.

## Release gate

The Windows release workflow runs `tools/Update-Contract.ps1` before building. A failing contract blocks publication. The source gate checks API and UI update capabilities and stable installer identity; it cannot prove settings retention on Windows by itself.

Before marking a release public, smoke-test on a clean Windows user profile and on an existing older installation:

- Install the previous public version and configure two distinct channel sounds, one Slack deep link, and nondefault deck settings.
- Verify **Check for Updates** finds the new version, offers the **real installer asset**, links to the SHA-256 checksum, and provides clear instructions.
- Run the installer interactively without uninstalling the old app; ensure settings, channel sounds, native links, Router and deck still work.
- Verify the new version badge and **Up to date** result after upgrade.
- Test graceful handling of unavailable GitHub metadata and a release with no installer asset.
- Verify that neither update discovery nor a cancelled download changes Slack sound ownership or user configuration.

**Compatibility note:** Existing installers published before this contract may only link to GitHub's release page. The guarantee is enforced for releases built after this policy and gate are added to the installer workflow.