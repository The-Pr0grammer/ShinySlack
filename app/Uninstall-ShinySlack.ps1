param([switch]$KeepFiles)

$ErrorActionPreference = 'SilentlyContinue'

$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'

Unregister-ScheduledTask `
    -TaskName 'ShinySlack Watcher' `
    -Confirm:$false |
    Out-Null

Remove-ItemProperty `
    -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
    -Name 'ShinySlackWatcher' `
    -ErrorAction SilentlyContinue

$pidFile = Join-Path $root 'watcher.pid'

if(Test-Path $pidFile) {
    $watcherPid = [int](Get-Content $pidFile -Raw)

    Stop-Process `
        -Id $watcherPid `
        -Force `
        -ErrorAction SilentlyContinue
}

$routerPath = Join-Path $root 'ChannelRouter.ps1'

Get-CimInstance Win32_Process `
    -Filter "Name='powershell.exe'" `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.CommandLine -and
    $_.CommandLine.IndexOf(
        $routerPath,
        [StringComparison]::OrdinalIgnoreCase
    ) -ge 0 -and
    $_.CommandLine -notmatch 'Start-ChannelRouter\.ps1'
} |
ForEach-Object {
    Stop-Process `
        -Id $_.ProcessId `
        -Force `
        -ErrorAction SilentlyContinue
}

$startup = [Environment]::GetFolderPath('Startup')

Remove-Item `
    (Join-Path $startup 'ShinySlack-Watcher.cmd') `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    (Join-Path $startup 'ShinySlack-ChannelRouter.cmd') `
    -Force `
    -ErrorAction SilentlyContinue

if(!$KeepFiles -and (Test-Path $root)) {
    Remove-Item $root -Recurse -Force
}

try {
    $shortcut =
        Join-Path `
            ([Environment]::GetFolderPath('Desktop')) `
            'ShinySlack.lnk'

    if(Test-Path $shortcut) {
        Remove-Item $shortcut -Force
    }
}
catch {}

Write-Host 'ShinySlack watcher/router removed.'
