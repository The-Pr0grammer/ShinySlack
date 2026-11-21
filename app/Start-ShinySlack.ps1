$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# Fallback for users who launch this .ps1 directly instead of Start-ShinySlack.cmd.
# Extracted files from an internet-downloaded ZIP may retain Mark-of-the-Web.
try { Get-ChildItem -LiteralPath $here -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}
$web = Join-Path $here 'ShinySlack-Web.ps1'
$stateRoot = Join-Path $env:LOCALAPPDATA 'ShinySlack'
$portFile = Join-Path $stateRoot 'web.port'
$outLog = Join-Path $stateRoot 'web-server.stdout.log'
$errLog = Join-Path $stateRoot 'web-server.stderr.log'
$traceLog = Join-Path $stateRoot 'web-trace.log'

function Test-ShinySlackUrl {
    param([string]$Url)
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Open-ShinySlackUrl {
    param([string]$Url)
    Start-Process $Url | Out-Null
}

function Ensure-ShinySlackRouter {
    try {
        if(!(Test-Path $stateRoot)) {
            New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        }

        $startupDir = [Environment]::GetFolderPath('Startup')
        $startupCmd = Join-Path $startupDir 'ShinySlack-ChannelRouter.cmd'

        $cmdText =
            "@echo off`r`n" +
            "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"%LOCALAPPDATA%\ShinySlack\Start-ChannelRouter.ps1`"`r`n"

        Set-Content `
            -LiteralPath $startupCmd `
            -Value $cmdText `
            -Encoding ASCII

        $launcher = Join-Path $stateRoot 'Start-ChannelRouter.ps1'

        if(Test-Path -LiteralPath $launcher) {
            $psExe = Join-Path $env:SystemRoot `
                'System32\WindowsPowerShell\v1.0\powershell.exe'

            Start-Process `
                -FilePath $psExe `
                -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`"" `
                -WindowStyle Hidden |
                Out-Null
        }
    }
    catch {}
}

try {
    # Always replace an older ShinySlack web backend with the launcher's own build.
    # This prevents a stale V1-V4 server from serving an older UI/API after an upgrade.
    try {
        $existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'ShinySlack-Web\.ps1' -and $_.ProcessId -ne $PID }
        foreach ($ep in @($existing)) {
            Stop-Process -Id $ep.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($existing) { Start-Sleep -Milliseconds 500 }
    } catch {}
    Remove-Item $portFile -Force -ErrorAction SilentlyContinue

    if (!(Test-Path $web)) {
        throw "Missing backend file: $web`nExtract the entire ShinySlack ZIP before launching it."
    }

    if (!(Test-Path $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    Ensure-ShinySlackRouter

    Remove-Item $outLog,$errLog,$traceLog -Force -ErrorAction SilentlyContinue

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -NoBrowser' -f $web
    $proc = Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250

        if (Test-Path $portFile) {
            try {
                $port = [int](Get-Content $portFile -Raw)
                $fallbackUrl = "http://127.0.0.1:$port/"
                $prettyUrl   = "http://localhost:$port/"

                $url = $fallbackUrl

                if(Test-ShinySlackUrl $prettyUrl) {
                    $url = $prettyUrl
                }
                if (Test-ShinySlackUrl $url) {
                    Open-ShinySlackUrl $url
                    exit 0
                }
            } catch {}
        }

        if ($null -eq $proc -or $proc.HasExited) { break }
    }

    $details = @()
    if (Test-Path $traceLog) {
        $t = [string](Get-Content $traceLog -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $t) { $t = $t.Trim() }
        if ($t) { $details += "TRACE:`n$t" }
    }
    if (Test-Path $errLog) {
        $e = [string](Get-Content $errLog -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $e) { $e = $e.Trim() }
        if ($e) { $details += "STDERR:`n$e" }
    }
    if (Test-Path $outLog) {
        $o = [string](Get-Content $outLog -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $o) { $o = $o.Trim() }
        if ($o) { $details += "STDOUT:`n$o" }
    }
    if (!$details.Count) {
        if ($null -eq $proc) {
            $details += 'Backend process did not start.'
        } elseif ($proc.HasExited) {
            $details += "Backend exited with code $($proc.ExitCode), but produced no log output."
        } else {
            $details += 'Backend did not become reachable within 12 seconds.'
        }
    }

    throw ("ShinySlack could not start.`n`n" + ($details -join "`n`n") + "`n`nLogs:`n$traceLog`n$outLog`n$errLog")
}
catch {
    Write-Host ''
    Write-Host 'SHINYSLACK STARTUP ERROR' -ForegroundColor Red
    Write-Host '------------------------' -ForegroundColor DarkRed
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Press Enter to close this window.' -ForegroundColor Gray
    [void](Read-Host)
    exit 1
}

