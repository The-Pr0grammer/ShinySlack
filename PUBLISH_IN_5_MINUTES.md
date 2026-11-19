# Publish ShinySlack in ~5 minutes

## Fastest route

Open PowerShell **inside this repo folder**.

1. Confirm Git exists:

```powershell
git --version
```

2. Install GitHub CLI if needed:

```powershell
winget install --id GitHub.cli -e
```

3. Sign in once:

```powershell
gh auth login
```

Choose **GitHub.com → HTTPS → Login with a web browser**.

4. Publish everything:

```powershell
powershell -ExecutionPolicy Bypass -File .\Publish-ShinySlack.ps1
```

The script creates/pushes the public `ShinySlack` repo, enables GitHub Pages, and pushes `v0.1.0-beta`.

That tag triggers GitHub Actions on a Windows runner. The workflow installs Inno Setup, compiles `ShinySlackSetup.exe`, calculates its SHA-256, and creates the GitHub Release.

The Pages workflow deploys the landing page. Its **Download for Windows** button points automatically to the latest release installer.

## URLs

After publish, the script prints your exact URLs. They will follow this shape:

```text
https://github.com/YOUR_USERNAME/ShinySlack
https://github.com/YOUR_USERNAME/ShinySlack/releases/latest
https://YOUR_USERNAME.github.io/ShinySlack/
```

## If the release workflow fails

Open the repo → **Actions → Build Windows installer and release**. The PowerShell parser validation and Inno Setup build output should identify the exact failure.

## First coworker test

Do this before blasting the link around:

- Download the installer from the public landing page on a second Windows profile/machine.
- Confirm Windows/SmartScreen behavior.
- Install without admin rights.
- Prime Knock Brush with one real Slack notification.
- Apply a short MP3.
- Confirm all four ShinySlack status cards are healthy.
- Log out/in or reboot and confirm `Watcher: Watching` returns.

Then send the landing-page URL to coworkers.
