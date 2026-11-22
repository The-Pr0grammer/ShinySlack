# ShinySlack beta release checklist

For v2.7.7: verify the three deck growth states, resize, hover help after hide/reopen, the dashboard Open Deck control, the installer hash, and Check for Updates from a v2.7.5 installation.

- [ ] Confirm V16 all-green dashboard on the development machine.
- [ ] Confirm `app/` PowerShell parser validation passes in GitHub Actions.
- [ ] Test installer on a second Windows machine/user profile.
- [ ] Verify standard Slack install/cache discovery.
- [ ] Apply a small MP3 without FFmpeg.
- [ ] Apply an oversized MP3 with FFmpeg installed.
- [ ] Reboot/log out and verify watcher startup.
- [ ] Clear/rebuild Slack cache and verify safe recovery behavior.
- [ ] Confirm uninstall removes watcher startup entry and shortcuts.
- [ ] Review workplace/device policy before distributing internally.
- [ ] Consider code signing before broad public distribution.
