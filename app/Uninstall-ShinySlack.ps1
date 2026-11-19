param([switch]$KeepFiles)
$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
Unregister-ScheduledTask -TaskName 'ShinySlack Watcher' -Confirm:$false | Out-Null
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ShinySlackWatcher' -ErrorAction SilentlyContinue
$pidFile = Join-Path $root 'watcher.pid'
if (Test-Path $pidFile) {
    $watcherPid = [int](Get-Content $pidFile -Raw)
    Stop-Process -Id $watcherPid -Force -ErrorAction SilentlyContinue
}
if (!$KeepFiles -and (Test-Path $root)) { Remove-Item $root -Recurse -Force }
try {
    $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ShinySlack.lnk'
    if (Test-Path $shortcut) { Remove-Item $shortcut -Force }
} catch {}
Write-Host 'ShinySlack watcher removed. This does not rewrite the current Slack cache back to stock; a Slack cache rebuild/update will naturally restore stock.'
