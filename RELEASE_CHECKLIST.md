# ShinySlack beta release checklist

For v2.7.9: verify persistent volume after release/reopen, low/muted red indicators in both deck modes, compact volume accessibility, four-corner resize, header drag, double-click minimize/restore, palette-cycling ShinySlack glow and sparkle, and automatic unmute after both interfaces close. Verify Test Slackbot, real Slack notifications, installer checksum, safe upgrade and Check for Updates from the older installer.

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
