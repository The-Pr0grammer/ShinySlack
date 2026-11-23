# SHINY-HTML-OWNERSHIP-HANDOFF-V1
[CmdletBinding()]
param([switch]$Start)
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'ShinySlack'
$deck=Join-Path $root 'HtmlDeck'
$exe=Join-Path $deck 'host\app\ShinySlack.HtmlDeck.Host.exe'
$supervisor=Join-Path $deck 'Start-HTMLDeck-Prod-v10.ps1'
$native=Join-Path $root 'PersistentAlerts.ps1'
$pulsePath=Join-Path $root 'HtmlDeck-visible.heartbeat.json'
$ownerPath=Join-Path $root 'HtmlDeck-heartbeat-ownership.flag'
$manifestPath=Join-Path $deck 'promotion-v10-stage.json'
$log=Join-Path $root 'HtmlDeck-ownership-handoff-v1.log'
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Log([string]$s){try{[IO.File]::AppendAllText($log,([DateTime]::UtcNow.ToString('o')+' '+$s+[Environment]::NewLine))}catch{}}
function Native {
 return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop | Where-Object {
   $_.CommandLine -and $_.CommandLine.IndexOf($native,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -match '(?i)\s-File\s'
 })
}
function Html {
 return @(Get-CimInstance Win32_Process -Filter "Name='ShinySlack.HtmlDeck.Host.exe'" -ErrorAction Stop | Where-Object {
   $_.ExecutablePath -and [string]::Equals([string]$_.ExecutablePath,$exe,[StringComparison]::OrdinalIgnoreCase)
 })
}
function Healthy([int]$processId) {
 try {
   $p=Get-Content -LiteralPath $pulsePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
   $age=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$p.timestampUtc)).TotalSeconds
   return ($p.rendererReady -eq $true -and [int]$p.pid -eq $processId -and $age -ge -5 -and $age -le 10 -and $p.visible -eq $true)
 }catch{return $false}
}
function SupervisorActive {
 try {$m=[Threading.Mutex]::OpenExisting('Local\ShinySlackHtmlProdFailoverSupervisorV10');$m.Dispose();return $true}
 catch [Threading.WaitHandleCannotBeOpenedException] {return $false}
 catch {return $true}
}
function RestoreNative {
 try {
   if(@(Native).Count -eq 0) {
      Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$native+'"') -WorkingDirectory $root -WindowStyle Hidden -ErrorAction Stop | Out-Null
      Log 'Fallback requested: native deck relaunched.'
   }
 } catch {Log ('WARNING: native fallback start failed: '+$_.Exception.Message)}
}
if(!$Start){Write-Host 'Use -Start for guarded HTML ownership handoff.';return}
$created=$false
$gate=[System.Threading.Mutex]::new($true,'Local\ShinySlackHtmlOwnershipHandoffV1',[ref]$created)
if(!$created){$gate.Dispose();Log 'Another handoff already in progress.';return}
$nativeRetired=$false
try {
 foreach($p in @($exe,$supervisor,$native,$manifestPath)) {if(!(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing: $p"}}
 if(!(Test-Path -LiteralPath (Join-Path $deck 'production-enabled.flag'))) {throw 'Production route not enabled.'}

 if(SupervisorActive){
   if(@(Html).Count -eq 1){[IO.File]::WriteAllText((Join-Path $root 'HtmlDeck-show.request'),[DateTime]::UtcNow.ToString('o'))}
   Log 'Supervisor already active; restore requested.';return
 }
 $htmlAll=@(Get-CimInstance Win32_Process -Filter "Name='ShinySlack.HtmlDeck.Host.exe'" -ErrorAction Stop)
 $htmlInstalled=@(Html)
 if($htmlAll.Count -ne $htmlInstalled.Count -or $htmlInstalled.Count -gt 1){throw 'Multiple or unrelated HTML hosts detected; no takeover attempted.'}
 if($htmlInstalled.Count -eq 0){
   Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
   Log 'HTML host start requested.'
 }
 $healthy=$false; $pidHtml=0
 for($i=0;$i -lt 20;$i++){
   $h=@(Html)
   if($h.Count -eq 1){$pidHtml=[int]$h[0].ProcessId;if(Healthy $pidHtml){$healthy=$true;break}}
   Start-Sleep -Seconds 1
 }
 if(!$healthy){throw 'HTML host did not publish healthy visible renderer heartbeat; native left untouched.'}
 # Preflight source and promotion manifest before touching the native deck.
 # The supervisor's integrity validation is retained as-is. A mismatch aborts safely.
 $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
 if([string]$manifest.Schema -ne 'html-deck-prod-stage-v10'){throw 'Unexpected promotion manifest schema.'}
 $pairs=@(
   @((Join-Path $deck 'host\app\deck-live.html'),[string]$manifest.HtmlSha),
   @((Join-Path $deck 'deck-live.html'),[string]$manifest.HtmlSha),
   @((Join-Path $deck 'host\app\deck-live.js'),[string]$manifest.JsSha),
   @((Join-Path $deck 'deck-live.js'),[string]$manifest.JsSha),
   @($exe,[string]$manifest.HostExeSha),
   @((Join-Path $deck 'host\Program.cs'),[string]$manifest.SourceSha)
 )
 foreach($pair in $pairs){
   if(!(Test-Path -LiteralPath $pair[0])){throw ('Missing promoted asset '+$pair[0])}
   if((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pair[1].ToLowerInvariant()){
     throw ('Promotion manifest mismatch; native preserved: '+$pair[0])
   }
 }
 $nativeRunning=@(Native)
 if($nativeRunning.Count -gt 1){throw 'Multiple native processes; refusing automatic takeover.'}
 if($nativeRunning.Count -eq 1){
   $n=$nativeRunning[0]
   $current=Get-CimInstance Win32_Process -Filter ("ProcessId="+[int]$n.ProcessId) -ErrorAction Stop
   if(!$current -or !$current.CommandLine -or $current.CommandLine.IndexOf($native,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw 'Native PID changed; not stopping.'}
   Stop-Process -Id ([int]$n.ProcessId) -Force -ErrorAction Stop
   $nativeRetired=$true
   Log ('Retired one verified native deck PID '+$n.ProcessId+' after HTML health and integrity checks.')
   for($i=0;$i -lt 15;$i++){if(@(Native).Count -eq 0){break};Start-Sleep -Milliseconds 400}
   if(@(Native).Count -gt 0){throw 'Native process still present; supervisor takeover aborted.'}
 }
 & $supervisor -Start -EnableNativeFailover -OwnHeartbeat | Out-Null
 for($i=0;$i -lt 18;$i++){
   if((SupervisorActive) -and (Test-Path -LiteralPath $ownerPath) -and (Healthy $pidHtml)){
     Log ('PASS: supervised HTML ownership acquired PID '+$pidHtml);return
   }
   Start-Sleep -Seconds 1
 }
 throw 'HTML supervisor did not establish owner flag within 18 seconds.'
} catch {
 Log ('Handoff aborted: '+$_.Exception.Message)
 if($nativeRetired){RestoreNative}
 Write-Warning ('HTML ownership handoff aborted: '+$_.Exception.Message)
} finally {$gate.ReleaseMutex();$gate.Dispose()}