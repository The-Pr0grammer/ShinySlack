$ErrorActionPreference = 'Stop'

$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
$build = 'V16'
$traceLog = Join-Path $root 'watcher.trace.log'
$heartbeatFile = Join-Path $root 'watcher.heartbeat.json'
$pidFile = Join-Path $root 'watcher.pid'
$lockPath = Join-Path $root 'watcher.lock'
$lockStream = $null

function Write-WatcherTrace {
    param([string]$Message)
    try {
        if (!(Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [IO.File]::AppendAllText($traceLog, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
        try { [Console]::Out.WriteLine($line) } catch {}
    } catch {}
}

function Write-WatcherHeartbeat {
    param([int]$Cycle,[string]$State,[int]$Poll)
    try {
        [pscustomobject]@{
            pid=$PID
            cycle=$Cycle
            state=$State
            build=$build
            pollSeconds=$Poll
            updated=(Get-Date).ToString('o')
        } | ConvertTo-Json -Compress | Set-Content $heartbeatFile -Encoding UTF8
    } catch {
        Write-WatcherTrace "Heartbeat write failed: $($_.Exception.Message)"
    }
}

try {
    if (!(Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    Write-WatcherTrace "Watcher process booting. Build=$build PID=$PID Script=$PSCommandPath"

    # Lifetime lock: an existing watcher keeps this file open with FileShare.None.
    # The OS releases the handle automatically if that process dies.
    try {
        $lockStream = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch {
        Write-WatcherTrace "Watcher launch exited: another watcher owns the lock. $($_.Exception.Message)"
        exit 0
    }

    . (Join-Path $PSScriptRoot 'ShinySlack.Common.ps1')
    Write-WatcherTrace 'Loaded ShinySlack.Common.ps1.'

    Set-Content $pidFile $PID -Encoding ASCII
    $config = Get-ShinySlackConfig
    $poll = [Math]::Max(15, [int]$config.PollSeconds)
    $cycle = 0
    Write-WatcherHeartbeat -Cycle $cycle -State 'Started' -Poll $poll
    Write-WatcherTrace "Watcher initialized. Poll=${poll}s."
    Write-ShinyLog "Watcher started. PID=$PID Poll=${poll}s. SLA-safe: live Slack is never force-closed."

    while ($true) {
        $cycle++
        $state = 'Checking'
        Write-WatcherHeartbeat -Cycle $cycle -State $state -Poll $poll
        try {
            $running = [bool](Get-Process slack -ErrorAction SilentlyContinue)

            if ($running) {
                $state='SlackRunningDeferred'
                Write-ShinyLog "Watcher check #${cycle}: Slack=Running; deepHash=Deferred; action=None; next=${poll}s"
            }
            else {
                $health = Get-ShinyStateHealth
                $state="SlackClosed:$health"
                Write-ShinyLog "Watcher check #${cycle}: Slack=Closed; deepHash=$health"

                if ($health -eq 'Custom') {
                    Write-ShinyLog "Watcher check #${cycle}: action=None; custom payload verified; next=${poll}s"
                }
                else {
                    Write-ShinyLog "Watcher check #${cycle}: action=Repair; reason=$health"
                    try {
                        $result = Invoke-ShinyRepair -RestartSlack $false -Quiet
                        $after = Get-ShinyStateHealth
                        $state="Repair:${result}:${after}"
                        Write-ShinyLog "Watcher repair #${cycle}: result=$result; after=$after; next=${poll}s"
                    } catch {
                        $state='RepairError'
                        Write-ShinyLog "Watcher repair #${cycle} failed: $($_.Exception.Message); next=${poll}s"
                        Write-WatcherTrace "Cycle #${cycle} repair failed: $($_.Exception.ToString())"
                    }
                }
            }
        } catch {
            $state='CycleError'
            Write-ShinyLog "Watcher check #${cycle} error: $($_.Exception.Message); next=${poll}s"
            Write-WatcherTrace "Cycle #${cycle} error: $($_.Exception.ToString())"
        }
        Write-WatcherHeartbeat -Cycle $cycle -State $state -Poll $poll
        Start-Sleep -Seconds $poll
    }
}
catch {
    $msg = "WATCHER FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-WatcherTrace $msg
    try { Write-WatcherTrace ("STACK: " + $_.ScriptStackTrace) } catch {}
    try { Write-ShinyLog $msg } catch {}
    try { [Console]::Error.WriteLine($msg) } catch {}
    exit 1
}
finally {
    try { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $heartbeatFile -Force -ErrorAction SilentlyContinue } catch {}
    try { if ($lockStream) { $lockStream.Dispose() } } catch {}
}
