# SHINY-HTML-PRODUCTION-BRIDGE-V10: production route, preserving native priority.
# SHINY-HTML-DECK-INTEGRATED-BRIDGE-V9: separate, serialized user-facing launcher.
# Windows PowerShell 5.1. No writes to dashboard source, no global/native process kill.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'ShinySlack'
$base=Join-Path $root 'HtmlDeck'
$guard=Join-Path $base 'Start-HTMLDeck-Prod-v10.ps1'
$exe=Join-Path $base 'host\app\ShinySlack.HtmlDeck.Host.exe'
$native=Join-Path $root 'PersistentAlerts.ps1'
$flag=Join-Path $base 'production-enabled.flag'
$legacyRouteFlag=Join-Path $root 'HtmlDeckDev-route.enabled'
$ownerFlag=Join-Path $root 'HtmlDeck-heartbeat-ownership.flag'
$nativeShow=Join-Path $root 'persistent-alerts-show.request'
$log=Join-Path $root 'HtmlDeck-integrated-v10.log'
$supervisorMutex='Local\ShinySlackHtmlProdFailoverSupervisorV10'
$nativeMutex='Local\ShinySlackPersistentAlertsV6'
$bridgeMutex='Local\ShinySlackHtmlProdBridgeV10'
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8=New-Object System.Text.UTF8Encoding($false)
function Log([string]$message){
    try {
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::AppendAllText($log,([DateTime]::UtcNow.ToString('o')+' '+$message+[Environment]::NewLine),$utf8)
    } catch { }
}
function Mutex-Present([string]$name){
    try {$handle=[Threading.Mutex]::OpenExisting($name);$handle.Dispose();return $true}
    catch [Threading.WaitHandleCannotBeOpenedException]{return $false}
    catch{return $true}
}
function Get-Html {
    return @(Get-CimInstance Win32_Process -Filter "Name='ShinySlack.HtmlDeck.Host.exe'" -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -and [string]::Equals([string]$_.ExecutablePath,$exe,[StringComparison]::OrdinalIgnoreCase)
    })
}
function Native-Present {
    if(Mutex-Present $nativeMutex){return $true}
    $running=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf($native,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine.IndexOf('-File',[StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    return ($running.Count -gt 0)
}
function Show-Native {
    [IO.File]::WriteAllText($nativeShow,[DateTime]::UtcNow.ToString('o'),$utf8)
    Log 'Requested native deck show/restore.'
}
function Native-FailOpen([string]$reason){
    Log ('Guard failed: '+$reason)
    # No destructive action: fail open only if HTML, owner, and supervisor are absent.
    if(Native-Present){Show-Native;return}
    if((Get-Html).Count -gt 0 -or @(Get-CimInstance Win32_Process -Filter "Name='ShinySlack.HtmlDeck.Host.exe'" -ErrorAction Stop).Count -gt 0 -or (Test-Path -LiteralPath $ownerFlag) -or (Mutex-Present $supervisorMutex)){
        Log 'Native fail-open blocked: HTML/supervisor/ownership may still be active.'
        return
    }
    if(!(Test-Path -LiteralPath $native -PathType Leaf)){Log 'Native fail-open blocked: native script missing.';return}
    Show-Native
    Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$native+'"') -WorkingDirectory $root -WindowStyle Hidden -ErrorAction Stop | Out-Null
    Log 'Requested native WinForms fail-open (starting; not yet health-confirmed).'
}
[void][IO.Directory]::CreateDirectory($root)
$created=$false
$gate=[System.Threading.Mutex]::new($true,$bridgeMutex,[ref]$created)
if(-not $created){$gate.Dispose();return}
try {
    # v5.1 disable removes this flag. A surviving shortcut must never bypass that rollback.
    if(!(Test-Path -LiteralPath $flag -PathType Leaf)){
        Native-FailOpen 'v5.1 HTML route disabled.'
        return
    }
    if(Native-Present){Show-Native;Log 'Native already active; skipped HTML supervisor.';return}
    if(!(Test-Path -LiteralPath $guard -PathType Leaf)){
        Native-FailOpen 'V10 supervisor file absent.'
        return
    }
    if(!(Test-Path -LiteralPath $exe -PathType Leaf)){
        Native-FailOpen 'HTML host executable absent.'
        return
    }
    # SHINY-HTML-PROD-RESTORE-BRIDGE-V10.2: one stable process snapshot, then direct restore.
    # Do NOT spawn a second HTML host when a single installed renderer is already healthy.
    $htmlAll = @(Get-CimInstance Win32_Process -Filter "Name='ShinySlack.HtmlDeck.Host.exe'" -ErrorAction Stop)
    $htmlInstalled = @($htmlAll | Where-Object {
        $_.ExecutablePath -and [string]::Equals([string]$_.ExecutablePath,$exe,[StringComparison]::OrdinalIgnoreCase)
    })
    if($htmlAll.Count -ne $htmlInstalled.Count -or $htmlInstalled.Count -gt 1){
        Log ('Refusing launch: unrelated/multiple HTML renderers. total='+$htmlAll.Count+' installed='+$htmlInstalled.Count)
        return
    }
    if($htmlInstalled.Count -eq 1){
        $livePid = [int]$htmlInstalled[0].ProcessId
        $pulsePath = Join-Path $root 'HtmlDeck-visible.heartbeat.json'
        $pulseHealthy = $false
        try {
            $pulse = Get-Content -LiteralPath $pulsePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $pulseAge = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$pulse.timestampUtc)).TotalSeconds
            $pulseHealthy = ($pulse.rendererReady -eq $true -and [int]$pulse.pid -eq $livePid -and $pulseAge -ge -5 -and $pulseAge -le 12)
        } catch { $pulseHealthy = $false }
        if($pulseHealthy){
            [IO.File]::WriteAllText((Join-Path $root 'HtmlDeck-show.request'),[DateTime]::UtcNow.ToString('o'),$utf8)
            Log ('V10.2 restore request written for healthy installed HTML PID '+$livePid+'; supervisor='+[string](Mutex-Present $supervisorMutex))
        }else{
            Log ('V10.2 existing installed HTML PID '+$livePid+' is not pulse-confirmed healthy; supervisor remains responsible for recovery.')
        }
        return
    }
    try {
        & $guard -Start -EnableNativeFailover -OwnHeartbeat *>$null
        Log 'V10.2 supervised HTML start requested; awaiting asynchronous health/fallback state.'
    } catch {
        Native-FailOpen $_.Exception.Message
    }
} catch {
    Log ('Bridge unexpected error: '+$_.Exception.Message)
} finally {
    $gate.ReleaseMutex()
    $gate.Dispose()
}
