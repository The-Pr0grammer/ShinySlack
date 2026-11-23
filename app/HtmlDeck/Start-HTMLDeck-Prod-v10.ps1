# SHINY-HTML-PRODUCTION-SUPERVISOR-V10: source-derived from tested V8 supervisor.
# ShinySlack HTML Deck V8: opt-in production failover supervisor.
# Windows PowerShell 5.1. Never patches repo-backed dashboard or existing shortcuts.
# Default is READ ONLY. -Start -EnableNativeFailover is required for native fallback.
[CmdletBinding()]
param(
  [switch]$Start,
  [switch]$Monitor,
  [switch]$EnableNativeFailover,
  [switch]$OwnHeartbeat,
  [switch]$Stop
)
$ErrorActionPreference='Stop'
if(($Start -and $Monitor) -or ($Start -and $Stop) -or ($Monitor -and $Stop)){throw 'Choose one of -Start, -Monitor or -Stop.'}
$worktree=Join-Path $env:LOCALAPPDATA 'ShinySlack\HtmlDeck'
$base=$worktree
$hostDir=Join-Path $base 'host'
$exe=Join-Path $hostDir 'app\ShinySlack.HtmlDeck.Host.exe'
$hostSource=Join-Path $hostDir 'Program.cs'
$root=Join-Path $env:LOCALAPPDATA 'ShinySlack'
$nativeScript=Join-Path $root 'PersistentAlerts.ps1'
$ownerFlag=Join-Path $root 'HtmlDeck-heartbeat-ownership.flag'
$devPulse=Join-Path $root 'HtmlDeck-visible.heartbeat.json'
$devShow=Join-Path $root 'HtmlDeck-show.request'
$statusPath=Join-Path $root 'HtmlDeck-failover.status.json'
$stopRequest=Join-Path $root 'HtmlDeck-failover.stop.request'
$supervisorMutex='Local\ShinySlackHtmlProdFailoverSupervisorV10'
$nativeMutex='Local\ShinySlackPersistentAlertsV6'
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8=New-Object System.Text.UTF8Encoding($false)
$ownerToken=''
function Get-HtmlInstances {
  $files=@(Get-CimInstance Win32_Process -Filter "Name = 'ShinySlack.HtmlDeck.Host.exe'" -ErrorAction Stop)
  return @($files | Where-Object { $_.ExecutablePath -and [string]::Equals([string]$_.ExecutablePath,$exe,[StringComparison]::OrdinalIgnoreCase) })
}
function Get-NativeState {
  $mutexPresent=$true
  try { $m=[Threading.Mutex]::OpenExisting($nativeMutex); $m.Dispose(); $mutexPresent=$true }
  catch [Threading.WaitHandleCannotBeOpenedException] { $mutexPresent=$false }
  catch { $mutexPresent=$true }
  $matches=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop | Where-Object {
     $_.CommandLine -and $_.CommandLine.IndexOf($nativeScript,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
     $_.CommandLine.IndexOf('-File',[StringComparison]::OrdinalIgnoreCase) -ge 0
  })
  return [pscustomobject]@{Present=($mutexPresent -or $matches.Count -gt 0); Mutex=$mutexPresent; Processes=$matches.Count}
}
function Get-Pulse {
  if(!(Test-Path -LiteralPath $devPulse -PathType Leaf)){return $null}
  try { return (Get-Content -LiteralPath $devPulse -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
  catch { return $null }
}
function Pulse-IsHealthy($pulse,[int]$targetProcessId) {
  if($null -eq $pulse -or $null -eq $pulse.rendererReady -or !$pulse.rendererReady){return $false}
  if([int]$pulse.pid -ne $targetProcessId){return $false}
  try {$age=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$pulse.timestampUtc)).TotalSeconds}
  catch {return $false}
  return ($age -ge -5 -and $age -le 12 -and [string]$pulse.mode -notin @('renderer-failed','user-exit','exited'))
}
function Pulse-IsUserExit($pulse,[int]$targetProcessId) {
  if($null -eq $pulse -or [string]$pulse.mode -ne 'user-exit' -or [int]$pulse.pid -ne $targetProcessId){return $false}
  try {$age=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$pulse.timestampUtc)).TotalSeconds}
  catch {return $false}
  return ($age -ge -5 -and $age -le 20)
}
function Write-Status([string]$phase,[string]$detail,[int]$htmlProcessId) {
  try {
    [void][IO.Directory]::CreateDirectory($root)
    $obj=[ordered]@{schema='html-deck-prod-failover-v10';timestampUtc=[DateTime]::UtcNow.ToString('o');supervisorPid=$PID;phase=$phase;detail=$detail;htmlPid=$htmlProcessId;fallbackEnabled=[bool]$EnableNativeFailover;heartbeatRequested=[bool]$OwnHeartbeat}
    [IO.File]::WriteAllText($statusPath,($obj|ConvertTo-Json -Depth 3),$utf8)
  } catch { }
}
function Release-Owner {
  if(!$ownerToken){return}
  try {
    if(Test-Path -LiteralPath $ownerFlag -PathType Leaf){
      $actual=[IO.File]::ReadAllText($ownerFlag)
      if($actual -eq $ownerToken){Remove-Item -LiteralPath $ownerFlag -Force -ErrorAction Stop}
    }
  } catch { Write-Status 'owner-release-warning' $_.Exception.Message 0 }
  $script:ownerToken=''
}
function Stop-VerifiedHtml([int]$targetProcessId) {
  $match=@(Get-HtmlInstances | Where-Object {$_.ProcessId -eq $targetProcessId})
  if($match.Count -eq 1){Stop-Process -Id $targetProcessId -Force -ErrorAction Stop}
  for($n=0;$n -lt 12;$n++){
    Start-Sleep -Milliseconds 300
    if(@(Get-HtmlInstances).Count -eq 0){return $true}
  }
  return $false
}
function Start-NativeFallback([string]$reason,[int]$targetProcessId) {
  Release-Owner
  Write-Status 'fallback-evaluating' $reason $targetProcessId
  if(!$EnableNativeFailover){Write-Status 'fallback-not-authorized' $reason $targetProcessId;return}
  $native=Get-NativeState
  if($native.Present){Write-Status 'native-already-present' $reason $targetProcessId;return}
  $htmlInstances=@(Get-HtmlInstances)
  if($htmlInstances.Count -gt 1){Write-Status 'blocked-multiple-html' 'Refusing to kill multiple HTML instances.' 0;return}
  if($htmlInstances.Count -eq 1){
    if(!(Stop-VerifiedHtml ([int]$htmlInstances[0].ProcessId))){Write-Status 'blocked-html-running' 'Could not stop installed HTML host safely.' 0;return}
  }
  if(@(Get-HtmlInstances).Count -gt 0){Write-Status 'blocked-html-running' 'HTML host still present.' 0;return}
  if((Get-NativeState).Present){Write-Status 'native-already-present' $reason 0;return}
  if(!(Test-Path -LiteralPath $nativeScript -PathType Leaf)){Write-Status 'blocked-native-missing' $nativeScript 0;return}
  $argsText='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$nativeScript+'"'
  try {
    Start-Process -FilePath $psExe -ArgumentList $argsText -WorkingDirectory $root -WindowStyle Hidden -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 2
    if((Get-NativeState).Present){Write-Status 'fallback-native-launched' $reason 0}
    else {Write-Status 'fallback-native-unconfirmed' 'Start request issued but native not detected yet.' 0}
  }catch{Write-Status 'fallback-launch-failed' $_.Exception.Message 0}
}
function Supervisor-IsRunning {
  try {$m=[Threading.Mutex]::OpenExisting($supervisorMutex); $m.Dispose();return $true}
  catch [Threading.WaitHandleCannotBeOpenedException]{return $false}
  catch{return $true}
}
function Assert-DevEnvironment {
  $manifestPath=Join-Path $base 'promotion-v10-stage.json'
  foreach($f in @($hostSource,$exe,$nativeScript,$manifestPath,(Join-Path $base 'deck-live.js'),(Join-Path $base 'deck-live.html'))){
    if(!(Test-Path -LiteralPath $f -PathType Leaf)){throw ('Missing installed release file: '+$f)}
  }
  $content=[IO.File]::ReadAllText($hostSource,[Text.Encoding]::UTF8)
  if(!$content.Contains('SHINY-HTML-PRODUCTION-PROMOTION-V10') -or !$content.Contains('rendererReady = ready')){throw 'Installed production renderer source marker invalid.'}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  if([string]$manifest.Schema -ne 'html-deck-prod-stage-v10'){throw 'Unexpected installed release manifest.'}
  foreach($pair in @(@($exe,[string]$manifest.HostExeSha),@($hostSource,[string]$manifest.SourceSha),@((Join-Path $base 'deck-live.js'),[string]$manifest.JsSha),@((Join-Path $base 'deck-live.html'),[string]$manifest.HtmlSha),@((Join-Path $base 'host\app\deck-live.js'),[string]$manifest.JsSha),@((Join-Path $base 'host\app\deck-live.html'),[string]$manifest.HtmlSha))){
    if((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pair[1].ToLowerInvariant()){
      throw ('Installed HTML release integrity check failed: '+$pair[0])
    }
  }
}
if(!$Start -and !$Monitor -and !$Stop){
  Write-Host 'SHINYSLACK FAILOVER V10 - READ ONLY' -ForegroundColor Cyan
  Write-Host ('Installed HTML executable exists: '+(Test-Path -LiteralPath $exe))
  Write-Host ('Native fallback exists: '+(Test-Path -LiteralPath $nativeScript))
  Write-Host ('HTML production process count: '+@(Get-HtmlInstances).Count)
  $native=Get-NativeState
  Write-Host ('Native mutex: '+$native.Mutex+' native process count: '+$native.Processes)
  Write-Host ('Supervisor mutex: '+(Supervisor-IsRunning))
  Write-Host ('Heartbeat owner flag present: '+(Test-Path -LiteralPath $ownerFlag))
  if(Test-Path -LiteralPath $statusPath){
    Write-Host 'Last supervisor status:'
    Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8
  }
  Write-Host 'No processes or application files changed.'
  return
}
if($Stop){
  if(!(Supervisor-IsRunning)){
    Write-Host 'No V8 supervisor running. Nothing stopped.' -ForegroundColor Green
    return
  }
  [IO.File]::WriteAllText($stopRequest,[DateTime]::UtcNow.ToString('o'),$utf8)
  for($i=0;$i -lt 18;$i++){
    Start-Sleep -Milliseconds 500
    if(!(Supervisor-IsRunning)){
      Write-Host 'PASS: V8 supervisor stopped; no native fallback triggered.' -ForegroundColor Green
      return
    }
  }
  throw 'Supervisor has not stopped yet. Inspect status before altering the host.'
}
if($Monitor){
  # Invoked only by -Start in a separate hidden process. Double-starts are mutex-blocked.
  $created=$false
  $gate=[System.Threading.Mutex]::new($true,$supervisorMutex,[ref]$created)
  if(!$created){$gate.Dispose();return}
  $htmlProcessId=0
  try {
    Assert-DevEnvironment
    if((Get-NativeState).Present){Write-Status 'blocked-native-running' 'Native renderer already active.' 0;return}
    if(Test-Path -LiteralPath $ownerFlag){Write-Status 'blocked-owner-flag' 'Ownership already enabled by another tool.' 0;return}
    $instances=@(Get-HtmlInstances)
    if($instances.Count -gt 1){Write-Status 'blocked-multiple-html' 'More than one HTML process.' 0;return}
    if($instances.Count -eq 0){
      Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
      Write-Status 'starting-html' 'Started installed HTML host and waiting for rendererReady.' 0
    } else {
      [IO.File]::WriteAllText($devShow,[DateTime]::UtcNow.ToString('o'),$utf8)
      Write-Status 'waiting-for-existing-html' 'Existing installed HTML host found; checking renderer health.' ([int]$instances[0].ProcessId)
    }
    $healthy=$false
    for($n=0;$n -lt 26;$n++){
      if((Get-NativeState).Present){
        $instances=@(Get-HtmlInstances)
        if($instances.Count -eq 1){[void](Stop-VerifiedHtml ([int]$instances[0].ProcessId))}
        Write-Status 'native-took-priority' 'Native appeared during HTML startup; installed HTML host yielded.' 0
        return
      }
      $instances=@(Get-HtmlInstances)
      if($instances.Count -gt 1){Write-Status 'blocked-multiple-html' 'Multiple HTML instances during startup.' 0;return}
      if($instances.Count -eq 1){
        $htmlProcessId=[int]$instances[0].ProcessId
        if(Pulse-IsHealthy (Get-Pulse) $htmlProcessId){$healthy=$true;break}
      }
      Start-Sleep -Seconds 1
    }
    if(!$healthy){
      if($htmlProcessId -gt 0 -and (Pulse-IsUserExit (Get-Pulse) $htmlProcessId)){Write-Status 'user-exit-no-fallback' 'Intentional Exit during HTML startup.' $htmlProcessId;return}
      Start-NativeFallback 'HTML never published a healthy WebView2 pulse in 26 seconds.' $htmlProcessId;return
    }
    if($OwnHeartbeat){
      if((Get-NativeState).Present){Write-Status 'blocked-native-running' 'Native appeared before ownership.' $htmlProcessId;return}
      if(Test-Path -LiteralPath $ownerFlag){Write-Status 'blocked-owner-flag' 'Unexpected owner flag before opt-in.' $htmlProcessId;return}
      $script:ownerToken='v8-supervisor-'+[guid]::NewGuid().ToString('N')
      [IO.File]::WriteAllText($ownerFlag,$ownerToken,$utf8)
    }
    Write-Status 'html-healthy' 'Renderer ready and heartbeat fresh. Watchdog active.' $htmlProcessId
    $badCount=0
    while($true){
      Start-Sleep -Seconds 3
      if(Test-Path -LiteralPath $stopRequest){
        Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue
        Release-Owner
        Write-Status 'stopped-on-request' 'Supervisor stopped without launching fallback. HTML host remains running.' $htmlProcessId
        return
      }
      $native=Get-NativeState
      if($native.Present){
        Release-Owner
        # Give native priority: stop ONLY this installed HTML host so renderers do not compete.
        $instances=@(Get-HtmlInstances)
        if($instances.Count -eq 1){[void](Stop-VerifiedHtml ([int]$instances[0].ProcessId))}
        Write-Status 'native-took-priority' 'Native started externally; HTML yielded ownership.' $htmlProcessId
        return
      }
      $instances=@(Get-HtmlInstances)
      $pulse=Get-Pulse
      if($instances.Count -eq 0){
        if(Pulse-IsUserExit $pulse $htmlProcessId){
          Release-Owner
          Write-Status 'user-exit-no-fallback' 'Tray Exit was intentional; no native launch.' $htmlProcessId
          return
        }
        Start-NativeFallback 'HTML process exited unexpectedly.' $htmlProcessId
        return
      }
      if($instances.Count -gt 1){Release-Owner;Write-Status 'blocked-multiple-html' 'Multiple HTML processes detected.' $htmlProcessId;return}
      if([int]$instances[0].ProcessId -ne $htmlProcessId){
        Start-NativeFallback 'Monitored HTML PID changed unexpectedly.' $htmlProcessId
        return
      }
      if(Pulse-IsHealthy $pulse $htmlProcessId){
        $badCount=0
        Write-Status 'html-healthy' 'Renderer ready; heartbeat fresh.' $htmlProcessId
      }else{
        $badCount++
        Write-Status 'html-suspect' ('Health check failed '+$badCount+' of 5') $htmlProcessId
        if($badCount -ge 5){Start-NativeFallback 'HTML renderer heartbeat unhealthy for 15 seconds.' $htmlProcessId;return}
      }
    }
  }catch{
    Release-Owner
    Write-Status 'supervisor-error' $_.Exception.Message $htmlProcessId
  }finally{
    Release-Owner
    $gate.ReleaseMutex()
    $gate.Dispose()
  }
  return
}
if($Start){
  Assert-DevEnvironment
  if($OwnHeartbeat -and !$EnableNativeFailover){throw '-OwnHeartbeat requires -EnableNativeFailover during the v8 supervised test.'}
  if((Get-NativeState).Present){throw 'Native WinForms is running. Exit it first; no changes made.'}
  if(Supervisor-IsRunning){
    [IO.File]::WriteAllText($devShow,[DateTime]::UtcNow.ToString('o'),$utf8)
    Write-Host 'PASS: Existing V8 supervisor detected; HTML restore requested (no duplicate).' -ForegroundColor Green
    return
  }
  if(Test-Path -LiteralPath $ownerFlag){throw 'A production ownership flag already exists. Review supervisor state before relaunch.'}
  if(Test-Path -LiteralPath $stopRequest){Remove-Item -LiteralPath $stopRequest -Force}
  $argText='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Monitor'
  if($EnableNativeFailover){$argText+=' -EnableNativeFailover'}
  if($OwnHeartbeat){$argText+=' -OwnHeartbeat'}
  Start-Process -FilePath $psExe -ArgumentList $argText -WorkingDirectory $base -WindowStyle Hidden -ErrorAction Stop | Out-Null
  Write-Host 'START REQUESTED: V10 production failover monitor launched.' -ForegroundColor Green
  Write-Host 'Monitor checks WebView2 readiness and a fresh 4-second heartbeat. It does NOT edit the dashboard route.'
  if($EnableNativeFailover){Write-Host 'AUTOMATIC NATIVE FALLBACK IS ENABLED for this guarded production session.' -ForegroundColor Yellow}
  else{Write-Host 'Native fallback is NOT enabled; use -EnableNativeFailover for the controlled test.'}
  if($OwnHeartbeat){Write-Host 'Heartbeat opt-in will occur only after healthy HTML startup and absent native mutex.' -ForegroundColor Yellow}
  Write-Host ('Monitor status: '+$statusPath)
}
