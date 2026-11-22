param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Mp3Path,
    [int]$PollSeconds = 15,
    [int]$RestartCooldownMinutes = 15
)
$ErrorActionPreference = 'Stop'

# Preflight: refuse to install if any bundled PowerShell script has parser errors.
# This catches PowerShell 5.1 interpolation traps before a hidden watcher can fail.
$parseFailures = @()
Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors) {
        foreach ($pe in $errors) {
            $parseFailures += ("{0}:{1}: {2}" -f $_.Name,$pe.Extent.StartLineNumber,$pe.Message)
        }
    }
}
if ($parseFailures.Count) {
    throw ("ShinySlack script parse preflight failed: " + ($parseFailures -join ' | '))
}

$sourceMp3 = (Resolve-Path $Mp3Path).Path
if (!(Test-Path $sourceMp3)) { throw "MP3 not found: $Mp3Path" }

$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
$backupDir = Join-Path $root 'backups'
New-Item -ItemType Directory -Path $root -Force | Out-Null
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

# Stop any verified ShinySlack watcher from an older build before replacing its files.
$existingWatcherPath = Join-Path $root 'Watch-ShinySlack.ps1'
try {
    $existingWatchers = @(
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'Watch-ShinySlack\.ps1' -and
            $_.CommandLine.IndexOf($existingWatcherPath,[StringComparison]::OrdinalIgnoreCase) -ge 0
        }
    )
    foreach($ew in $existingWatchers){ Stop-Process -Id $ew.ProcessId -Force -ErrorAction SilentlyContinue }
    if($existingWatchers.Count){ Start-Sleep -Milliseconds 350 }
} catch {}

# Stop ONLY a verified existing ShinySlack watcher. A stale PID is never trusted.
$oldPidFile = Join-Path $root 'watcher.pid'
if (Test-Path $oldPidFile) {
    try {
        $oldPid = [int](Get-Content $oldPidFile -Raw)
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $oldPid) -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -match '^powershell(?:\.exe)?$' -and $proc.CommandLine -match 'Watch-ShinySlack\.ps1') {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Remove-Item $oldPidFile -Force -ErrorAction SilentlyContinue
}

function Copy-ShinyFileIfNeeded {
    param([string]$Source,[string]$Destination)
    if (!(Test-Path -LiteralPath $Source)) { throw "Kit is missing $Source" }
    $srcFull = [IO.Path]::GetFullPath($Source)
    $dstFull = [IO.Path]::GetFullPath($Destination)
    if ($srcFull.Equals($dstFull,[StringComparison]::OrdinalIgnoreCase)) { return }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

foreach ($name in @('ShinySlack.Common.ps1','Repair-ShinySlack.ps1','Watch-ShinySlack.ps1','Set-ShinySlackSound.ps1','Uninstall-ShinySlack.ps1','ShinySlack-Operation.ps1','ChannelRouter.ps1','Start-ChannelRouter.ps1','PersistentAlerts.ps1','Set-ChannelSound.ps1','Set-DefaultSound.ps1','silent-slack.mp3')) {
    $src = Join-Path $PSScriptRoot $name
    Copy-ShinyFileIfNeeded -Source $src -Destination (Join-Path $root $name)
}
Copy-Item $sourceMp3 (Join-Path $root 'custom.mp3') -Force
Set-Content (Join-Path $root 'agent.version') 'V17' -Encoding ASCII

# Persist the current web build with the installed app.
foreach ($webName in @('ShinySlack-Web.ps1','ShinySlack-Operation.ps1','index.html','Start-ShinySlack.cmd','Start-ShinySlack.ps1','Start-ShinySlack-Background.ps1','Install-ShinySlack.ps1','ShinySlack.ico','version.txt')) {
    $webSrc = Join-Path $PSScriptRoot $webName
    if (Test-Path $webSrc) { Copy-ShinyFileIfNeeded -Source $webSrc -Destination (Join-Path $root $webName) }
}

# SHINY-SOUND-PRESETS-INSTALL-V1
$presetSource =
    Join-Path `
        $PSScriptRoot `
        'presets'


if(Test-Path -LiteralPath $presetSource){

    $presetDestination =
        Join-Path `
            $root `
            'presets'


    New-Item `
        -ItemType Directory `
        -Path $presetDestination `
        -Force |
    Out-Null


    Copy-Item `
        -Path (
            Join-Path `
                $presetSource `
                '*'
        ) `
        -Destination $presetDestination `
        -Recurse `
        -Force
}

try { Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}

try {
    if (Test-Path (Join-Path $root 'Start-ShinySlack.ps1')) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shortcutPath = Join-Path $desktop 'ShinySlack.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $shortcut = $ws.CreateShortcut($shortcutPath)
        $launcherPs =
            Join-Path `
                $env:SystemRoot `
                'System32\WindowsPowerShell\v1.0\powershell.exe'

        $launcherScript =
            Join-Path `
                $root `
                'Start-ShinySlack.ps1'

        $shortcut.TargetPath =
            $launcherPs

        $shortcut.Arguments =
            (
                '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
                '-File "' +
                $launcherScript +
                '" -QuietLaunch'
            )
        $shortcut.WorkingDirectory = $root
        $iconPath = Join-Path $root 'ShinySlack.ico'
        if(Test-Path -LiteralPath $iconPath){
            $shortcut.IconLocation = "$iconPath,0"
        }
        else {
            $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,168"
        }
        $shortcut.Description = 'Open ShinySlack dashboard and notification alerts'
        $shortcut.Save()
    }
} catch {}

[pscustomobject]@{
    PollSeconds = [Math]::Max(15,$PollSeconds)
    RestartCooldownMinutes = [Math]::Max(5,$RestartCooldownMinutes)
    Installed = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content (Join-Path $root 'config.json') -Encoding UTF8

. (Join-Path $root 'ShinySlack.Common.ps1')
Write-ShinyLog "Install/update started with MP3: $sourceMp3"

# First repair validates the cache and sound. If custom is already present this is a fast no-op.
$result = Invoke-ShinyRepair -RestartSlack $true
Write-ShinyLog "Install repair result=$result"

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$watcher = Join-Path $root 'Watch-ShinySlack.ps1'
$watchArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""

# Persistence: use the current-user Startup folder. No scheduled-task registration and no admin rights.
$startupDir = [Environment]::GetFolderPath('Startup')
$startupCmd = Join-Path $startupDir 'ShinySlack-Watcher.cmd'
$cmdText = "@echo off`r`nstart `"`" /min `"$psExe`" $watchArgs`r`n"
Set-Content -Path $startupCmd -Value $cmdText -Encoding ASCII
Write-ShinyLog "Installed watcher startup entry: $startupCmd"

$routerStartupCmd = Join-Path $startupDir 'ShinySlack-ChannelRouter.cmd'

$routerCmdText =
    "@echo off`r`n" +
    "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"%LOCALAPPDATA%\ShinySlack\Start-ChannelRouter.ps1`"`r`n" +
    "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"%LOCALAPPDATA%\ShinySlack\PersistentAlerts.ps1`"`r`n"
Set-Content `
    -LiteralPath $routerStartupCmd `
    -Value $routerCmdText `
    -Encoding ASCII

$routerLauncher = Join-Path $root 'Start-ChannelRouter.ps1'

if(Test-Path -LiteralPath $routerLauncher) {
    Start-Process `
        -FilePath $psExe `
        -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$routerLauncher`"" `
        -WindowStyle Hidden |
        Out-Null
}

Write-ShinyLog "Installed channel-router startup entry: $routerStartupCmd"
# SHINY-V17-PERSISTENT-ALERTS-INSTALL-V2
# Startup persistence is owned by ShinySlack-ChannelRouter.cmd.
# Remove the old separate entry if upgrading from an earlier prototype.
$alertsStartupCmd =
    Join-Path `
        $startupDir `
        'ShinySlack-PersistentAlerts.cmd'

Remove-Item `
    -LiteralPath $alertsStartupCmd `
    -Force `
    -ErrorAction SilentlyContinue

$alertsScript =
    Join-Path `
        $root `
        'PersistentAlerts.ps1'

if(Test-Path -LiteralPath $alertsScript) {
    Start-Process `
        -FilePath $psExe `
        -ArgumentList (
            "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"" +
            $alertsScript +
            "`""
        ) `
        -WindowStyle Hidden |
    Out-Null
}

Write-ShinyLog "Persistent alerts started; Startup persistence is consolidated with the channel router."


# Remove legacy persistence from older builds so it cannot spawn duplicates.
try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ShinySlackWatcher' -ErrorAction SilentlyContinue } catch {}
try { Unregister-ScheduledTask -TaskName 'ShinySlack Watcher' -Confirm:$false -ErrorAction SilentlyContinue } catch {}

# Start watcher now. Diagnostics are split so the watcher never writes to a file
# that Start-Process itself has locked for stdout/stderr redirection.
$watchStdout = Join-Path $root 'watcher.stdout.log'
$watchStderr = Join-Path $root 'watcher.stderr.log'
$watchTrace = Join-Path $root 'watcher.trace.log'
$heartbeat = Join-Path $root 'watcher.heartbeat.json'
Remove-Item $watchStdout,$watchStderr,$watchTrace,$heartbeat -Force -ErrorAction SilentlyContinue

$watchProc = Start-Process $psExe -ArgumentList $watchArgs -WindowStyle Hidden -RedirectStandardOutput $watchStdout -RedirectStandardError $watchStderr -PassThru
Write-ShinyLog "Watcher launch requested. PID=$($watchProc.Id)"

$watcherOk = $false
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if (Test-ShinyWatcherRunning) { $watcherOk = $true; break }
    if ($watchProc.HasExited) { break }
}

if (!$watcherOk) {
    $parts=@()
    if ($watchProc.HasExited) { $parts += "exitCode=$($watchProc.ExitCode)" }
    if (Test-Path $watchTrace) { try { $t=((Get-Content $watchTrace -Tail 8 -Encoding UTF8)-join ' | ').Trim(); if($t){$parts += "trace=$t"} } catch {} }
    if (Test-Path $watchStderr) { try { $e=((Get-Content $watchStderr -Tail 8 -Encoding UTF8)-join ' | ').Trim(); if($e){$parts += "stderr=$e"} } catch {} }
    if (!$parts.Count) { $parts += 'no heartbeat/process detected and no diagnostic output was produced' }
    $reason=$parts -join ' ; '
    Write-ShinyLog "WARNING: watcher did not remain running. $reason"
    Write-Warning "Sound is installed, but the watcher did not remain running. $reason"
} else {
    $hb=Get-ShinyWatcherHeartbeat
    $detail = if($hb){"heartbeatAge=$($hb.AgeSeconds)s state=$($hb.Data.state)"}else{'process-detected'}
    Write-ShinyLog "Watcher verified running. PID=$($watchProc.Id) $detail"
}

Write-Host ''
Write-Host "ShinySlack sound status: $result"
Write-Host "Permanent folder: $root"
Write-Host ("Watcher: " + $(if($watcherOk){'RUNNING'}else{'NOT RUNNING'}))
Write-Host 'Test with a REAL incoming Slack notification.'

