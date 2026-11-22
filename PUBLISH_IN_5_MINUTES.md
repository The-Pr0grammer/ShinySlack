# Publish ShinySlack

## Release path

Current maintenance release: **v2.7.6**. Preserve the existing v2.7.5 tag/assets; publish a new tag from the same tested main HEAD.

ShinySlack's public user flow is:

1. GitHub Pages landing page.
2. `ShinySlackSetup.exe`.
3. Installer creates the branded **ShinySlack** Desktop and Start-menu shortcuts.
4. Setup launches ShinySlack.
5. The local dashboard opens and the persistent alert deck/router start.
6. Later, the user simply opens **ShinySlack** again from Desktop or Start.

The landing page discovers the newest non-draft GitHub Release that actually contains `ShinySlackSetup.exe`, including prereleases. It does not assume that the newest Git tag has a release asset.

## Before cutting a release

Open PowerShell in the repository and confirm:

```powershell
git status
git branch --show-current
Get-Content .\app\version.txt
```

Release tags must point at `main` HEAD and match `app/version.txt`.

## Build/publish

A `v*` tag on `main` triggers `.github/workflows/release.yml`.

The workflow:

- validates every bundled PowerShell script;
- verifies the install/run UX contract;
- compiles the Inno Setup installer;
- generates `ShinySlackSetup.exe.sha256`; and
- publishes the installer + checksum to the GitHub Release.

The GitHub Pages landing page is deployed from `docs/` whenever `docs/**` changes on `main`.

## Fresh-machine smoke test

Before sharing the public landing-page URL, test from a second Windows profile or clean machine:

1. Open the public ShinySlack landing page.
2. Confirm the main button resolves to a real `ShinySlackSetup.exe` release asset.
3. Download the installer and checksum.
4. Run the installer without admin rights.
5. Confirm the installer shows ShinySlack branding/icon.
6. Confirm **Open ShinySlack now** is offered at the end.
7. Confirm the first launch opens the local dashboard and starts the alert deck.
8. Close the dashboard and deck.
9. Double-click the branded **ShinySlack** Desktop shortcut.
10. Confirm the dashboard and deck reopen.
11. Confirm the Start-menu **ShinySlack** shortcut does the same.
12. Confirm Slack built-in notifications produce audio + a deck alert + Activity.
13. Confirm a notification on another monitor is still detected.
14. Confirm Windows Action Center-only notifications are correctly documented as unsupported.
15. Log out/in or reboot and confirm the background router/deck persistence returns.
16. Uninstall ShinySlack and confirm the Desktop shortcut, Startup entries, router, deck, and web backend are removed.

Only after this passes should the landing-page URL be handed to fresh users.
