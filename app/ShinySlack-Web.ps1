param([int]$Port = 38721,[switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$script:StopServer = $false
# SHINY-PRIVACY-CRYPTO-WEB-TOKEN-V1
$tokenBytes =
    New-Object byte[] 32

$tokenRng =
    [Security.Cryptography.RandomNumberGenerator]::Create()

try {

    $tokenRng.GetBytes(
        $tokenBytes
    )


    $script:Token =
        [Convert]::ToBase64String(
            $tokenBytes
        )
}
finally {

    [Array]::Clear(
        $tokenBytes,
        0,
        $tokenBytes.Length
    )


    $tokenRng.Dispose()
}
$script:Root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
$script:SourceDir = $PSScriptRoot
$script:Build = 'V17'
$script:HistoryFeatureEnabled = $false # v2.7.5 privacy baseline
$script:TraceLog = Join-Path $script:Root 'web-trace.log'

function Write-WebDiag {
    param([string]$Message,[string]$RequestId='SERVER')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $RequestId, $Message
    # Mirror every checkpoint to stdout AND a dedicated trace file.
    # stdout is redirected by the launcher to web-server.stdout.log.
    try { [Console]::Out.WriteLine($line) } catch {}
    try {
        if(!(Test-Path $script:Root)){ New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
        [IO.File]::AppendAllText($script:TraceLog, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch {
        try { [Console]::Out.WriteLine(("{0} [LOGGER] TRACE WRITE FAILED: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $_.Exception.Message)) } catch {}
    }
}
function Write-WebException {
    param($ErrorRecord,[string]$RequestId='SERVER',[string]$Context='Unhandled exception')
    try {
        Write-WebDiag "$Context :: $($ErrorRecord.Exception.GetType().FullName): $($ErrorRecord.Exception.Message)" $RequestId
        if($ErrorRecord.ScriptStackTrace){ Write-WebDiag ("STACK: " + ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | ')) $RequestId }
        if($ErrorRecord.Exception.InnerException){ Write-WebDiag ("INNER: " + $ErrorRecord.Exception.InnerException.ToString()) $RequestId }
        Write-WebDiag ("FULL: " + ($ErrorRecord.ToString() -replace "`r?`n", ' | ')) $RequestId
    } catch {}
}

function Get-PersistentAlertSettings {

    $path =
        Join-Path $script:Root 'persistent-alerts.json'

    $enabled = $true


    if(Test-Path -LiteralPath $path) {

        try {

            $cfg =
                Get-Content `
                    -LiteralPath $path `
                    -Raw `
                    -Encoding UTF8 `
                    -ErrorAction Stop |
                ConvertFrom-Json


            if($null -ne $cfg.autoDismiss) {

                $enabled =
                    [bool]$cfg.autoDismiss
            }
        }
        catch {}
    }


    [pscustomobject]@{
        autoDismiss = $enabled
        autoDismissSeconds = 15
    }
}


function Set-PersistentAlertSettings {

    param(
        [bool]$AutoDismiss
    )


    $path =
        Join-Path $script:Root 'persistent-alerts.json'

    $tmp =
        $path + '.tmp'


    $json =
        [pscustomobject]@{
            autoDismiss = $AutoDismiss
            autoDismissSeconds = 15
        } |
        ConvertTo-Json


    [IO.File]::WriteAllText(
        $tmp,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )


    Move-Item `
        -LiteralPath $tmp `
        -Destination $path `
        -Force


    Get-PersistentAlertSettings
}

Write-WebDiag "ShinySlack web backend booting. Build=$script:Build PID=$PID SourceDir=$script:SourceDir"

function Sync-InstalledShinySlackAgent {
    # Opening a newer extracted build upgrades the installed runtime agent without
    # touching Slack, the custom sound, or the Chromium cache.
    try {
        if(!(Test-Path $script:Root)){ New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
        $sourceFull=[IO.Path]::GetFullPath($script:SourceDir).TrimEnd('\\')
        $rootFull=[IO.Path]::GetFullPath($script:Root).TrimEnd('\\')
        if($sourceFull -eq $rootFull){ return }

        $configPath=Join-Path $script:Root 'config.json'
        $runtime=@('ShinySlack.Common.ps1','Repair-ShinySlack.ps1','Watch-ShinySlack.ps1','Set-ShinySlackSound.ps1','Uninstall-ShinySlack.ps1','ShinySlack-Operation.ps1','ChannelRouter.ps1','Start-ChannelRouter.ps1','PersistentAlerts.ps1','Set-ChannelSound.ps1','Set-DefaultSound.ps1','silent-slack.mp3')
        $web=@('ShinySlack-Web.ps1','index.html','Start-ShinySlack.cmd','Start-ShinySlack.ps1','Start-ShinySlack-Background.ps1','Install-ShinySlack.ps1','ShinySlack.ico','version.txt')

        # Validate every PowerShell file before copying anything into the installed app.
        $parseFailures=@()
        foreach($f in Get-ChildItem -LiteralPath $script:SourceDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue){
            $tokens=$null; $errors=$null
            [System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors) | Out-Null
            foreach($pe in @($errors)){
                if($pe){ $parseFailures += ("{0}:{1}: {2}" -f $f.Name,$pe.Extent.StartLineNumber,$pe.Message) }
            }
        }
        if($parseFailures.Count){ throw ('Package parser preflight failed: ' + ($parseFailures -join ' | ')) }

        $sourceWatcher=Join-Path $script:SourceDir 'Watch-ShinySlack.ps1'
        $installedWatcher=Join-Path $script:Root 'Watch-ShinySlack.ps1'
        $needsAgentUpgrade=$false
        if(Test-Path $sourceWatcher){
            if(!(Test-Path $installedWatcher)){ $needsAgentUpgrade=$true }
            else {
                $a=(Get-FileHash $sourceWatcher -Algorithm SHA256).Hash
                $b=(Get-FileHash $installedWatcher -Algorithm SHA256).Hash
                $needsAgentUpgrade=($a -ne $b)
            }
        }
        $versionPath=Join-Path $script:Root 'agent.version'
        $oldVersion=if(Test-Path $versionPath){(Get-Content $versionPath -Raw -ErrorAction SilentlyContinue).Trim()}else{''}
        if($oldVersion -ne $script:Build){ $needsAgentUpgrade=$true }

        if($needsAgentUpgrade -and (Test-Path $configPath)){
            Write-WebDiag "Installed agent upgrade detected: $oldVersion -> $script:Build. Stopping old watcher only; Slack will not be touched." 'UPGRADE'
            try {
                $watcherPath=[IO.Path]::GetFullPath($installedWatcher)
                $procs=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
                    $_.CommandLine -and $_.CommandLine -match 'Watch-ShinySlack\.ps1' -and $_.CommandLine.IndexOf($watcherPath,[StringComparison]::OrdinalIgnoreCase) -ge 0
                })
                foreach($proc in $procs){ Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
                if($procs.Count){ Start-Sleep -Milliseconds 400 }
            } catch { Write-WebException $_ 'UPGRADE' 'Stopping previous watcher failed' }
        }

        foreach($name in ($runtime+$web)){
            $src=Join-Path $script:SourceDir $name
            if(Test-Path $src){ Copy-Item $src (Join-Path $script:Root $name) -Force }
        }
        # SHINY-SOUND-PRESETS-SYNC-V1
        $presetSource =
            Join-Path `
                $script:SourceDir `
                'presets'


        if(Test-Path -LiteralPath $presetSource){

            $presetDestination =
                Join-Path `
                    $script:Root `
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

        Set-Content $versionPath $script:Build -Encoding ASCII
        try { Get-ChildItem -LiteralPath $script:Root -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}

        if($needsAgentUpgrade -and (Test-Path $configPath)){
            # Old diagnostics belong to the previous build; archive them instead of
            # presenting them as a failure from the new watcher.
            $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
            foreach($name in @('watcher.trace.log','watcher.stdout.log','watcher.stderr.log','watcher.heartbeat.json','watcher.pid')){
                $path=Join-Path $script:Root $name
                if(Test-Path $path){
                    if($name -like '*.log'){ try { Move-Item $path (Join-Path $script:Root ($name+'.pre-'+$stamp)) -Force } catch { Remove-Item $path -Force -ErrorAction SilentlyContinue } }
                    else { Remove-Item $path -Force -ErrorAction SilentlyContinue }
                }
            }
            Remove-Item (Join-Path $script:Root 'watcher.lock') -Force -ErrorAction SilentlyContinue

            $psExe=Join-Path $env:SystemRoot 'System32\\WindowsPowerShell\\v1.0\\powershell.exe'
            $watcher=Join-Path $script:Root 'Watch-ShinySlack.ps1'
            $stdout=Join-Path $script:Root 'watcher.stdout.log'
            $stderr=Join-Path $script:Root 'watcher.stderr.log'
            $args="-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""
            $proc=Start-Process $psExe -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
            Write-WebDiag "Upgraded watcher launch requested. PID=$($proc.Id)" 'UPGRADE'

            $deadline=(Get-Date).AddSeconds(6); $ok=$false
            while((Get-Date) -lt $deadline){
                Start-Sleep -Milliseconds 250
                $hbPath=Join-Path $script:Root 'watcher.heartbeat.json'
                if(Test-Path $hbPath){
                    try { $hb=Get-Content $hbPath -Raw -Encoding UTF8 | ConvertFrom-Json; if([string]$hb.build -eq $script:Build){$ok=$true;break} } catch {}
                }
                if($proc.HasExited){break}
            }
            if($ok){ Write-WebDiag "Upgraded watcher heartbeat confirmed for $script:Build." 'UPGRADE' }
            else {
                $detail=if($proc.HasExited){"exitCode=$($proc.ExitCode)"}else{'no fresh heartbeat yet'}
                Write-WebDiag "Upgraded watcher did not confirm: $detail" 'UPGRADE'
            }
        }
    } catch {
        Write-WebException $_ 'UPGRADE' 'Agent auto-upgrade failed'
    }
}

Sync-InstalledShinySlackAgent

$mutex = New-Object System.Threading.Mutex -ArgumentList $false, 'Local\ShinySlackWebServerV17PA1'
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0,$false) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }
if (!$hasMutex) {
    $portFile = Join-Path $script:Root 'web.port'
    if (Test-Path $portFile) { try { Start-Process ("http://127.0.0.1:{0}/" -f ([int](Get-Content $portFile -Raw))) } catch {} }
    $mutex.Dispose(); exit 0
}

function Send-Response {
    param($Client,[int]$Status=200,[string]$ContentType='application/json; charset=utf-8',[string]$Body='')
    $stream=$Client.GetStream(); $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    $reason = if($Status -eq 200){'OK'}elseif($Status -eq 202){'Accepted'}elseif($Status -eq 400){'Bad Request'}elseif($Status -eq 403){'Forbidden'}elseif($Status -eq 404){'Not Found'}else{'Error'}
    $header="HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`nX-Content-Type-Options: nosniff`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($header);$stream.Write($hb,0,$hb.Length);if($bytes.Length){$stream.Write($bytes,0,$bytes.Length)};$stream.Flush()
}
function Json-Response { param($Client,$Object,[int]$Status=200); Send-Response $Client $Status 'application/json; charset=utf-8' ($Object|ConvertTo-Json -Depth 8 -Compress) }
function Read-Request {
    param(
        $Client,
        [string]$RequestId='REQ'
    )

    $Client.NoDelay = $true
    $Client.ReceiveTimeout = 3000
    $Client.SendTimeout = 5000

    $stream = $Client.GetStream()

    # --------------------------------------------------------
    # FIRST BYTE
    #
    # Firefox/Chromium may open speculative localhost sockets
    # that never actually send an HTTP request.
    #
    # This server is single-threaded, so those connections
    # must be discarded very quickly.
    # --------------------------------------------------------

    # SHINY-SPECULATIVE-SOCKET-SAFE-V2
    #
    # Firefox/Chromium may pre-open localhost sockets and send no HTTP
    # bytes. That is normal. Since this server is single-threaded, drop
    # those sockets quickly, but never turn them into a JSON 500 page.
    $stream.ReadTimeout = 250

    try {
        $firstByte = $stream.ReadByte()
    }
    catch [System.IO.IOException] {
        return $null
    }
    catch {
        return $null
    }

    if($firstByte -lt 0) {
        return $null
    }

    # Real request detected. Normal timeout from here forward.
    $stream.ReadTimeout = 3000
    $stream.WriteTimeout = 5000


    $head =
        New-Object System.IO.MemoryStream

    $seq =
        New-Object 'System.Collections.Generic.Queue[byte]'


    $head.WriteByte(
        [byte]$firstByte
    )

    $seq.Enqueue(
        [byte]$firstByte
    )


    while($true) {

        # Did the first byte somehow complete CRLFCRLF?
        # Impossible for a valid HTTP request, but maintain
        # one consistent queue algorithm.
        if($seq.Count -eq 4) {

            $a = $seq.ToArray()

            if(
                $a[0] -eq 13 -and
                $a[1] -eq 10 -and
                $a[2] -eq 13 -and
                $a[3] -eq 10
            ) {
                break
            }
        }


        $v =
            $stream.ReadByte()


        if($v -lt 0) {
            break
        }


        $head.WriteByte(
            [byte]$v
        )

        $seq.Enqueue(
            [byte]$v
        )


        while($seq.Count -gt 4) {
            $null = $seq.Dequeue()
        }


        if($seq.Count -eq 4) {

            $a =
                $seq.ToArray()


            if(
                $a[0] -eq 13 -and
                $a[1] -eq 10 -and
                $a[2] -eq 13 -and
                $a[3] -eq 10
            ) {
                break
            }
        }


        if($head.Length -gt 65536) {
            throw 'Request headers too large.'
        }
    }


    $hs =
        [Text.Encoding]::ASCII.GetString(
            $head.ToArray()
        )


    $lines =
        $hs -split "`r`n"


    $first =
        $lines[0] -split ' '


    if($first.Count -lt 2) {
        throw 'Invalid request line.'
    }


    $headers = @{}


    if($lines.Count -gt 1) {

        foreach(
            $line in
            $lines[1..($lines.Count-1)]
        ) {

            if(
                $line -match
                '^([^:]+):\s*(.*)$'
            ) {

                $headers[
                    $matches[1].ToLowerInvariant()
                ] = $matches[2]
            }
        }
    }


    $len = 0


    if(
        $headers.ContainsKey(
            'content-length'
        )
    ) {
        $len =
            [int]$headers['content-length']
    }


    if($len -gt 10MB) {
        throw "Request body too large: $len bytes."
    }


    Write-WebDiag `
        "Parsed $($first[0]) $($first[1]) Content-Length=$len" `
        $RequestId


    $bodyBytes =
        New-Object byte[] $len


    $off = 0


    while($off -lt $len) {

        $n =
            $stream.Read(
                $bodyBytes,
                $off,
                $len-$off
            )


        if($n -le 0) {
            break
        }


        $off += $n
    }


    if($off -ne $len) {

        throw (
            "Request body ended early: read " +
            "$off of $len bytes."
        )
    }


    $body =
        if($len) {

            [Text.Encoding]::UTF8.GetString(
                $bodyBytes,
                0,
                $off
            )
        }
        else {
            ''
        }


    [pscustomobject]@{
        Method  = $first[0]
        Path    = $first[1].Split('?')[0]
        Headers = $headers
        Body    = $body
    }
}

# SHINY-HISTORY-DEEPLINK-HELPERS-V1

function Get-SlackDesktopWorkspaces {

    $candidates =
        @(
            (
                Join-Path `
                    $env:APPDATA `
                    'Slack'
            ),
            (
                Join-Path `
                    $env:LOCALAPPDATA `
                    'Packages\com.tinyspeck.slackdesktop_8yrtsj140pw4g\LocalCache\Roaming\Slack'
            )
        )


    foreach(
        $candidate in
        $candidates
    ){

        $statePath =
            Join-Path `
                $candidate `
                'storage\root-state.json'


        if(!(Test-Path -LiteralPath $statePath)){
            continue
        }


        try {

            $state =
                Get-Content `
                    -LiteralPath $statePath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json


            $result =
                @()


            foreach(
                $property in
                $state.workspaces.PSObject.Properties
            ){

                $workspace =
                    $property.Value


                if(!$workspace.id){
                    continue
                }


                $result +=
                    [pscustomobject]@{
                        name =
                            [string]$workspace.name

                        domain =
                            [string]$workspace.domain

                        teamId =
                            [string]$workspace.id
                    }
            }


            return @(
                $result |
                Sort-Object name
            )
        }
        catch {}
    }


    return @()
}


function Protect-ShinySecret {
    param([string]$PlainText)

    $secure =
        ConvertTo-SecureString `
            -String $PlainText `
            -AsPlainText `
            -Force


    return ConvertFrom-SecureString `
        $secure
}


# SHINY-LIVE-ACTIVITY-FROM-ROUTER-V2
$script:LiveActivityCacheKey =
    ''

$script:LiveActivityCache =
    @()

$script:LiveActivityGeneration =
    [int64]0


function Get-LiveRouterActivityItems {
    param(
        [int]$Limit = 30
    )


    $routerLog =
        Join-Path `
            $script:Root `
            'channel-router.log'


    if(
        !(
            Test-Path `
                -LiteralPath $routerLog
        )
    ){
        return @()
    }


    try {

        $logInfo =
            Get-Item `
                -LiteralPath $routerLog `
                -ErrorAction Stop


        $cacheKey =
            '{0}:{1}' -f
            [int64]$logInfo.Length,
            [int64]$logInfo.LastWriteTimeUtc.Ticks


        if(
            $cacheKey -eq
            $script:LiveActivityCacheKey
        ){

            return @(
                $script:LiveActivityCache |
                Select-Object -First $Limit
            )
        }


        $palette =
            @(
                '#55d8ff',
                '#ff5cc8',
                '#63e6a3',
                '#ffc857',
                '#a78bfa',
                '#5ea1ff',
                '#ff7b72',
                '#b5e853',
                '#ff8fab',
                '#44d7c4'
            )


        function Get-LiveActivityAccentIndex {
            param(
                [string]$Key,
                [int]$PreviousIndex = -1
            )


            [uint64]$hash =
                0


            foreach(
                $ch in
                $Key.ToCharArray()
            ){

                $hash =
                    (
                        ($hash * 31) +
                        [int][char]$ch
                    ) % 4294967296
            }


            $index =
                [int](
                    $hash %
                    $palette.Count
                )


            if(
                $palette.Count -gt 1 -and
                $index -eq $PreviousIndex
            ){

                $index =
                    (
                        $index +
                        1
                    ) %
                    $palette.Count
            }


            return [int]$index
        }


        $activity =
            @()


        $previousAccentIndex =
            -1


        foreach(
            $line in
            @(
                Get-Content `
                    -LiteralPath $routerLog `
                    -Tail 8001 `
                    -Encoding UTF8 `
                    -ErrorAction Stop
            )
        ){

            if(
                [string]::IsNullOrWhiteSpace(
                    $line
                )
            ){
                continue
            }


            $candidate =
                $line.Trim()


            if(
                $candidate -notmatch
                '^(?<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) (?<kind>ROUTED|DEFAULT|STACK_EXTRA|STACK_EXTRA_DEFAULT) channel=(?<channel>\S+) sound=(?<sound>.+?) backend=(?<backend>\S+)(?:\s+.*)?$'
            ){
                continue
            }


            $stamp =
                [string]$Matches['stamp']

            $kind =
                [string]$Matches['kind']

            $channel =
                [string]$Matches['channel']

            $sound =
                [string]$Matches['sound']

            $backend =
                [string]$Matches['backend']


            try {

                $when =
                    [datetime]::ParseExact(
                        $stamp,
                        'yyyy-MM-dd HH:mm:ss.fff',
                        [Globalization.CultureInfo]::InvariantCulture
                    ).ToString('o')
            }
            catch {

                $when =
                    (Get-Date).ToString('o')
            }


            $source =
                $channel


            if(
                [string]::IsNullOrWhiteSpace(
                    $source
                ) -or
                $source -eq 'unknown'
            ){

                $source =
                    'Slack'
            }
            elseif(
                !$source.StartsWith(
                    '#'
                )
            ){

                $source =
                    '#' +
                    $source
            }


            $description =
                switch($kind){

                    'ROUTED' {
                        'Routed notification'
                    }

                    'DEFAULT' {
                        'Default notification'
                    }

                    'STACK_EXTRA' {
                        'Stacked routed notification'
                    }

                    'STACK_EXTRA_DEFAULT' {
                        'Stacked default notification'
                    }

                    default {
                        'Notification'
                    }
                }


            $accentIndex =
                Get-LiveActivityAccentIndex `
                    -Key $candidate `
                    -PreviousIndex $previousAccentIndex


            $previousAccentIndex =
                $accentIndex


            $activity +=
                [pscustomobject]@{
                    time =
                        $when

                    source =
                        $source

                    message =
                        $description

                    sound =
                        $sound

                    backend =
                        $backend

                    eventKey =
                        $candidate

                    accent =
                        [string]$palette[$accentIndex]
                }
        }


        $ordered =
            @(
                $activity |
                Sort-Object time -Descending |
                Select-Object -First 60
            )


        $script:LiveActivityCache =
            $ordered

        $script:LiveActivityCacheKey =
            $cacheKey

        $script:LiveActivityGeneration++


        return @(
            $ordered |
            Select-Object -First $Limit
        )
    }
    catch {

        return @(
            $script:LiveActivityCache |
            Select-Object -First $Limit
        )
    }
}


function Convert-LiveActivitySafe {
    param(
        [object[]]$Items
    )


    $safe =
        @()


    foreach(
        $n in
        @($Items)
    ){

        if($null -eq $n){
            continue
        }


        $safe +=
            [ordered]@{
                time =
                    [string]$n.time

                source =
                    [string]$n.source

                message =
                    [string]$n.message

                sound =
                    [string]$n.sound

                backend =
                    [string]$n.backend

                eventKey =
                    [string]$n.eventKey

                accent =
                    [string]$n.accent
            }
    }


    return @($safe)
}

function Get-NotificationLedgerItems {
    param(
        [int]$Limit = 30
    )

    $ledger =
        Join-Path `
            $script:Root `
            'notification-ledger.jsonl'


    if(!(Test-Path -LiteralPath $ledger)){
        return @()
    }


    $items =
        @()


    foreach(
        $line in
        @(
            Get-Content `
                -LiteralPath $ledger `
                -Tail 1000 `
                -Encoding UTF8 `
                -ErrorAction SilentlyContinue
        )
    ){

        if(
            [string]::IsNullOrWhiteSpace(
                $line
            )
        ){
            continue
        }


        try {

            $obj =
                $line |
                ConvertFrom-Json


            $items +=
                $obj
        }
        catch {}
    }


    return @(
        $items |
        Sort-Object time -Descending |
        Select-Object -First $Limit
    )
}


function Get-HistoryBackfillStatus {

    # SHINY-PRIVACY-HISTORY-DISABLED-275-V1
    [pscustomobject]@{
        enabled =
            $false

        connected =
            $false

        teamId =
            ''

        teamName =
            ''

        userName =
            ''

        lastRun =
            ''

        recoveredLastRun =
            0

        lastError =
            'History is disabled in v2.7.5 pending the v2.8 privacy design.'
    }
}

function Start-HistoryBackfillOnce {

    $worker =
        Join-Path `
            $script:Root `
            'HistoryBackfill.ps1'


    if(!(Test-Path -LiteralPath $worker)){
        throw 'HistoryBackfill.ps1 is missing.'
    }


    $ps =
        Join-Path `
            $env:SystemRoot `
            'System32\WindowsPowerShell\v1.0\powershell.exe'


    Start-Process `
        -FilePath $ps `
        -ArgumentList (
            '-NoProfile -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass ' +
            '-File "' +
            $worker +
            '" -Once'
        ) `
        -WindowStyle Hidden |
    Out-Null
}

function Get-SoundOwnershipStatus {
    param([bool]$RouterRunning)

    $modePath=Join-Path $script:Root 'sound-ownership.json'
    $guardPath=Join-Path $script:Root 'sound-safety-status.json'
    $configPath=Join-Path $script:Root 'channel-routes.json'

    $mode='legacy'
    $transition=$false
    $suppressed=$false
    $lastError=''

    if(Test-Path $modePath){
        try{
            $state=
                Get-Content `
                    $modePath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json

            if($state.mode){
                $mode=[string]$state.mode
            }

            $transition=[bool]$state.transition
            $suppressed=[bool]$state.nativeSuppressed
            $lastError=[string]$state.lastError
        }catch{}
    }

    $enabled=$true
    $volume=1.0
    $defaultReady=$false

    if(Test-Path $configPath){
        try{
            $cfg=
                Get-Content `
                    $configPath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json

            if($null -ne $cfg.enabled){
                $enabled=[bool]$cfg.enabled
            }

            if($null -ne $cfg.volume){
                $volume=[double]$cfg.volume
            }

            if(
                $cfg.defaultSound -and
                (Test-Path ([string]$cfg.defaultSound))
            ){
                $defaultReady=$true
            }
        }catch{}
    }

    $guardFresh=$false
    $guardState=''
    $guardMessage=''
    $guardHealthy=$false

    if(Test-Path $guardPath){
        try{
            $guard=
                Get-Content `
                    $guardPath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json

            $guardState=[string]$guard.state
            $guardMessage=[string]$guard.message
            $guardHealthy=[bool]$guard.routerHealthy

            if($guard.lastCheck){
                $age=(
                    (Get-Date) -
                    [datetime]::Parse([string]$guard.lastCheck)
                ).TotalSeconds

                $guardFresh=(
                    $age -ge 0 -and
                    $age -le 20
                )
            }
        }catch{}
    }

    $risk=$false

    if($mode -eq 'routerExclusive'){
        $risk=(
            !$RouterRunning -or
            !$defaultReady -or
            !$guardFresh -or
            !$guardHealthy
        )
    }

    [pscustomobject]@{
        mode=$mode
        transition=$transition
        nativeSuppressed=$suppressed
        routerRunning=$RouterRunning
        routerAudioEnabled=$enabled
        volume=$volume
        defaultReady=$defaultReady
        guardFresh=$guardFresh
        guardState=$guardState
        guardMessage=$guardMessage
        guardRouterHealthy=$guardHealthy
        risk=$risk
        audioIntentionallyMuted=(!$enabled -or $volume -le 0)
        lastError=$lastError
    }
}

function Get-StatusObject {
    param([string]$RequestId='STATUS')
    Write-WebDiag 'STATUS 1/8: checking install marker.' $RequestId
    $installed = (Test-Path (Join-Path $script:Root 'Set-ShinySlackSound.ps1')) -and (Test-Path (Join-Path $script:Root 'config.json'))

    Write-WebDiag 'STATUS 2/8: checking Slack process.' $RequestId
    $slackRunning = [bool](Get-Process slack -ErrorAction SilentlyContinue)

    Write-WebDiag 'STATUS 3/8: checking cache directory.' $RequestId
    $cache = Join-Path $env:APPDATA 'Slack\Cache\Cache_Data'
    $cachePresent = Test-Path $cache

    # IMPORTANT: do not read Chromium cache payloads from the web/status request
    # while Slack is running. On some Windows/Slack builds data_* can be held with
    # sharing semantics that make a live health probe stall the single-threaded API.
    $health = if($installed){'Unknown'}else{'Not installed'}
    if($installed -and $slackRunning){
        $statePath = Join-Path $script:Root 'state.json'
        if(Test-Path $statePath){
            $health = 'ConfiguredDeferred'
            Write-WebDiag 'STATUS 4/8: custom state exists; live deep check deferred because Slack is running.' $RequestId
        } else {
            $health = 'Deferred'
            Write-WebDiag 'STATUS 4/8: deep sound-health check deferred because Slack is running.' $RequestId
        }
    } elseif($installed) {
        Write-WebDiag 'STATUS 4/8: Slack closed; running deep sound-health check.' $RequestId
        try {
            . (Join-Path $script:Root 'ShinySlack.Common.ps1')
            $health = Get-ShinyStateHealth
        } catch {
            $health = 'Unknown'
            Write-WebException $_ $RequestId 'Status health check failed'
        }
    } else {
        Write-WebDiag 'STATUS 4/8: not installed; no health probe.' $RequestId
    }

    Write-WebDiag 'STATUS 5/8: checking watcher heartbeat only.' $RequestId

    $watcher = $false
    $watcherDetail = ''
    $hb = $null

    try {

        . (Join-Path $script:Root 'ShinySlack.Common.ps1')

        $hb =
            Get-ShinyWatcherHeartbeat


        if(
            $hb -and
            $hb.Fresh
        ) {

            $watcher = $true

            $watcherDetail =
                "$($hb.Data.build) heartbeat $($hb.AgeSeconds)s ago; $($hb.Data.state)"
        }
        elseif($hb) {

            $watcher = $false

            $watcherDetail =
                "stale heartbeat $($hb.AgeSeconds)s"
        }
        else {

            $watcher = $false
            $watcherDetail = 'no heartbeat'
        }
    }
    catch {

        $watcher = $false
        $watcherDetail = 'heartbeat unavailable'

        Write-WebException `
            $_ `
            $RequestId `
            'Status watcher heartbeat check failed'
    }

    Write-WebDiag 'STATUS 6/8: reading activity log tail newest-first.' $RequestId
    $log=''
    $logPath=Join-Path $script:Root 'ShinySlack.log'
    if(Test-Path $logPath){
        try {
            $lines = @(Get-Content $logPath -Tail 50 -Encoding UTF8 -ErrorAction Stop)
            [Array]::Reverse($lines)
            $log = $lines -join "`n"
        } catch { Write-WebException $_ $RequestId 'Status log read failed' }
    }
    if(!$watcher){
        $diagParts=@()
        foreach($wf in @('watcher.trace.log','watcher.stderr.log','watcher.stdout.log')){
            $wp=Join-Path $script:Root $wf
            if(Test-Path $wp){
                try{ $ls=@(Get-Content $wp -Tail 6 -Encoding UTF8 -ErrorAction Stop); if($ls.Count){ [Array]::Reverse($ls); $diagParts += ("${wf}:`n" + ($ls -join "`n")) } }catch{}
            }
        }
        if($diagParts.Count){ $diag=$diagParts -join "`n`n"; if($log){$log="WATCHER DIAGNOSTICS:`n$diag`n`n$log"}else{$log="WATCHER DIAGNOSTICS:`n$diag"} }
    }

    # Live Activity comes directly from the privacy-safe Router event log.
    # v2.8 recovered history will MERGE with this source later; it does not
    # replace the live feed.
    $notifications =
        @(
            Get-LiveRouterActivityItems `
                -Limit 30
        )
    Write-WebDiag 'STATUS 7/8: checking ffmpeg.' $RequestId
    $ffmpeg=[bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)

    Write-WebDiag 'STATUS 8A: building channel-audio status.' $RequestId

    $channelAudio =
        Get-ChannelAudioStatus

    Write-WebDiag 'STATUS 8B: channel-audio status complete.' $RequestId

    $agentBuild = ''

    if(
        $hb -and
        $hb.Data -and
        $hb.Data.build
    ) {
        $agentBuild =
            [string]$hb.Data.build
    }


    $statusObject =
        [pscustomobject]@{
            ok             = $true
            build          = $script:Build
            installed      = $installed
            slackRunning   = $slackRunning
            cachePresent   = $cachePresent
            health         = $health
            watcherRunning = $watcher
            watcherDetail  = $watcherDetail
            ffmpeg         = $ffmpeg
            log            = $log
            notifications  = @($notifications)
            agentBuild     = $agentBuild
            channelAudio   = $channelAudio
            historyBackfill = Get-HistoryBackfillStatus
            soundOwnership = Get-SoundOwnershipStatus -RouterRunning ([bool]$channelAudio.routerRunning)
        }


    Write-WebDiag 'STATUS 8/8: status object complete.' $RequestId

    $statusObject
}
function Persist-WebFiles {
    if(!(Test-Path $script:Root)){
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    }

    foreach(
        $name in
        @(
            'ShinySlack-Web.ps1',
            'ShinySlack-Operation.ps1',
            'index.html',
            'Start-ShinySlack.cmd',
            'Start-ShinySlack.ps1',
            'Start-ShinySlack-Background.ps1',
            'Install-ShinySlack.ps1',
            'ShinySlack.ico',
            'version.txt'
        )
    ){
        $src = Join-Path $script:SourceDir $name

        if(Test-Path $src){
            $dst = Join-Path $script:Root $name

            if(
                [IO.Path]::GetFullPath($src) -ne
                [IO.Path]::GetFullPath($dst)
            ){
                Copy-Item $src $dst -Force
            }
        }
    }

    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop 'ShinySlack.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($lnk)
        $psExe =
            Join-Path `
                $env:SystemRoot `
                'System32\WindowsPowerShell\v1.0\powershell.exe'

        $launchScript =
            Join-Path `
                $script:Root `
                'Start-ShinySlack.ps1'

        $s.TargetPath =
            $psExe

        $s.Arguments =
            (
                '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
                '-File "' +
                $launchScript +
                '" -QuietLaunch'
            )
        $s.WorkingDirectory = $script:Root

        $icon = Join-Path $script:Root 'ShinySlack.ico'
        if(Test-Path -LiteralPath $icon){
            $s.IconLocation = "$icon,0"
        }
        else {
            $s.IconLocation = "$env:SystemRoot\System32\shell32.dll,168"
        }

        $s.Description = 'Open ShinySlack dashboard and notification alerts'
        $s.Save()
    }
    catch {}
}
function Start-AsyncOperation {
    param([string]$Script,[string[]]$Arguments=@(),[string]$CleanupPath='',[string]$RequestId='SERVER')
    if(!(Test-Path $script:Root)){New-Item -ItemType Directory -Path $script:Root -Force|Out-Null}
    $ops=Join-Path $script:Root 'web-ops';New-Item -ItemType Directory -Path $ops -Force|Out-Null
    $id=[guid]::NewGuid().ToString('N');$state=Join-Path $ops "$id.state.json";$log=Join-Path $ops "$id.log";$request=Join-Path $ops "$id.request.json"
    Write-WebDiag "Creating async operation id=$id Script=$Script Arguments=$($Arguments -join ' | ')" $RequestId
    [pscustomobject]@{Script=$Script;Arguments=@($Arguments);CleanupPath=$CleanupPath;StatePath=$state;LogPath=$log}|ConvertTo-Json -Depth 5|Set-Content $request -Encoding UTF8
    [pscustomobject]@{status='queued';exitCode=-1;error='';updated=(Get-Date).ToString('o')}|ConvertTo-Json -Compress|Set-Content $state -Encoding UTF8
    $runner=Join-Path $script:SourceDir 'ShinySlack-Operation.ps1';if(!(Test-Path $runner)){$runner=Join-Path $script:Root 'ShinySlack-Operation.ps1'}
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $opProc=Start-Process $ps -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$runner,'-RequestFile',$request) -WindowStyle Hidden -PassThru
    Write-WebDiag "Async runner launched. operation=$id pid=$($opProc.Id) requestFile=$request" $RequestId
    $id
}
function Get-OperationObject {
    param([string]$Id)
    if($Id -notmatch '^[a-f0-9]{32}$'){throw 'Invalid operation id.'}
    $ops=Join-Path $script:Root 'web-ops';$state=Join-Path $ops "$Id.state.json";$log=Join-Path $ops "$Id.log"
    if(!(Test-Path $state)){throw 'Operation not found.'}
    $s=Get-Content $state -Raw -Encoding UTF8|ConvertFrom-Json;$out='';if(Test-Path $log){$out=(Get-Content $log -Tail 60 -Encoding UTF8)-join "`n"}
    [pscustomobject]@{ok=$true;status=$s.status;exitCode=$s.exitCode;error=$s.error;output=$out}
}


# SHINY-LINKED-CHANNEL-NAMES-V1
function Get-LinkedChannelNames {

    try {

        $cfg =
            Read-ChannelRoutesConfig


        if(
            $null -eq $cfg.deepLinks
        ){
            return @()
        }


        return @(
            $cfg.deepLinks.Keys |
            ForEach-Object {
                ([string]$_).Trim()
            } |
            Where-Object {
                $_
            } |
            Sort-Object -Unique
        )
    }
    catch {

        return @()
    }
}

# SHINY-SOUND-PRESETS-BACKEND-V1
function Get-SoundPresets {

    $dir =
        Join-Path `
            $script:Root `
            'presets'


    $manifestPath =
        Join-Path `
            $dir `
            'presets.json'


    if(!(Test-Path -LiteralPath $manifestPath)){
        return @()
    }


    try {

        $manifest =
            Get-Content `
                -LiteralPath $manifestPath `
                -Raw `
                -Encoding UTF8 `
                -ErrorAction Stop |
            ConvertFrom-Json


        $result =
            @()


        foreach($preset in @($manifest.presets)){

            if(!$preset){
                continue
            }


            $id =
                ([string]$preset.id).Trim()


            $name =
                ([string]$preset.name).Trim()


            $fileName =
                [IO.Path]::GetFileName(
                    [string]$preset.fileName
                )


            if(
                !$id -or
                !$name -or
                !$fileName
            ){
                continue
            }


            $path =
                Join-Path `
                    $dir `
                    $fileName


            if(!(Test-Path -LiteralPath $path)){
                continue
            }


            $result +=
                [pscustomobject]@{
                    id =
                        $id

                    name =
                        $name

                    fileName =
                        $fileName

                    path =
                        $path
                }
        }


        return @(
            $result |
            Sort-Object name
        )
    }
    catch {

        Write-WebException `
            $_ `
            'PRESETS' `
            'Could not load sound preset manifest'


        return @()
    }
}


function Resolve-SoundPreset {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PresetId
    )


    $id =
        $PresetId.Trim()


    if(!$id){
        throw 'Preset ID is required.'
    }


    $preset =
        @(
            Get-SoundPresets |
            Where-Object {
                [string]$_.id -eq
                $id
            }
        ) |
        Select-Object -First 1


    if(!$preset){
        throw 'Sound preset was not found.'
    }


    return $preset
}

# SHINY-PRESET-STATE-HELPER-V1
function Get-PresetIdForPath {
    param(
        [string]$Path
    )


    if(
        [string]::IsNullOrWhiteSpace(
            $Path
        )
    ){
        return ''
    }


    try {

        $full =
            [IO.Path]::GetFullPath(
                $Path
            )


        foreach($preset in @(Get-SoundPresets)){

            if(!$preset){
                continue
            }


            $presetFull =
                [IO.Path]::GetFullPath(
                    [string]$preset.path
                )


            if(
                $full.Equals(
                    $presetFull,
                    [StringComparison]::OrdinalIgnoreCase
                )
            ){

                return [string]$preset.id
            }
        }
    }
    catch {}


    return ''
}

function Get-ChannelAudioStatus {

    $routerLog =
        Join-Path `
            $script:Root `
            'channel-router.log'


    $routerStdout =
        Join-Path `
            $script:Root `
            'channel-router.stdout.log'


    $routerRunning =
        $false


    foreach(
        $heartbeatPath in
        @(
            $routerStdout,
            $routerLog
        )
    ){

        if(!(Test-Path -LiteralPath $heartbeatPath)){
            continue
        }


        try {

            $info =
                Get-Item `
                    -LiteralPath $heartbeatPath


            $age =
                (
                    (Get-Date).ToUniversalTime() -
                    $info.LastWriteTimeUtc
                ).TotalSeconds


            if($age -le 300){

                $routerRunning =
                    $true

                break
            }
        }
        catch {}
    }


    $cfg =
        Read-ChannelRoutesConfig


    $workspaces =
        @(
            Get-SlackDesktopWorkspaces
        )


    $routes =
        @()


    foreach(
        $channelName in
        @(
            $cfg.routes.Keys |
            Sort-Object
        )
    ){

        $name =
            ([string]$channelName).Trim()


        $link =
            $null


        if(
            $cfg.deepLinks.ContainsKey(
                $name
            )
        ){

            $link =
                $cfg.deepLinks[$name]
        }


        $linked =
            (
                $null -ne $link -and
                ![string]::IsNullOrWhiteSpace(
                    [string]$link.team
                ) -and
                ![string]::IsNullOrWhiteSpace(
                    [string]$link.channel
                )
            )


        $routes +=
            [pscustomobject]@{
                channel =
                    $name

                sound =
                    Split-Path `
                        -Leaf `
                        ([string]$cfg.routes[$channelName])

                # SHINY-PRESET-STATE-ROUTE-V1
                presetId =
                    Get-PresetIdForPath `
                        -Path ([string]$cfg.routes[$channelName])

                linked =
                    [bool]$linked

                team =
                    if($linked){
                        [string]$link.team
                    }
                    else {
                        ''
                    }

                channelId =
                    if($linked){
                        [string]$link.channel
                    }
                    else {
                        ''
                    }
            }
    }


    $lastDetected =
        ''


    if(Test-Path -LiteralPath $routerLog){

        try {

            $lines =
                @(
                    Get-Content `
                        -LiteralPath $routerLog `
                        -Tail 100 `
                        -Encoding UTF8
                )


            for(
                $i = $lines.Count - 1;
                $i -ge 0;
                $i--
            ){

                if(
                    $lines[$i] -match
                    'channel=#([^\s]+)'
                ){

                    $lastDetected =
                        '#' +
                        $Matches[1]

                    break
                }
            }
        }
        catch {}
    }


    [pscustomobject]@{
        routerRunning =
            $routerRunning

        enabled =
            [bool]$cfg.enabled

        volume =
            [double]$cfg.volume

        defaultSound =
            if($cfg.defaultSound){

                Split-Path `
                    -Leaf `
                    ([string]$cfg.defaultSound)
            }
            else {
                ''
            }

        # SHINY-PRESET-STATE-DEFAULT-V1
        defaultPresetId =
            Get-PresetIdForPath `
                -Path ([string]$cfg.defaultSound)

        routes =
            @($routes)

        deepLinks =
            $cfg.deepLinks

        linkedChannels =
            @(Get-LinkedChannelNames)

        workspaces =
            @($workspaces)

        lastDetected =
            $lastDetected
    }
}

function Read-ChannelRoutesConfig {

    $configPath =
        Join-Path `
            $script:Root `
            'channel-routes.json'


    $routes =
        @{}

    $deepLinks =
        @{}

    $enabled =
        $true

    $volume =
        1.0

    $defaultSound =
        $null


    if(Test-Path -LiteralPath $configPath){

        try {

            $raw =
                Get-Content `
                    -LiteralPath $configPath `
                    -Raw `
                    -Encoding UTF8 `
                    -ErrorAction Stop


            $cfg =
                $raw |
                ConvertFrom-Json


            if($null -ne $cfg.enabled){

                $enabled =
                    [bool]$cfg.enabled
            }


            if($null -ne $cfg.volume){

                $volume =
                    [double]$cfg.volume
            }


            if($null -ne $cfg.defaultSound){

                $defaultSound =
                    [string]$cfg.defaultSound
            }


            if($null -ne $cfg.routes){

                foreach(
                    $p in
                    $cfg.routes.PSObject.Properties
                ){

                    $routes[
                        ([string]$p.Name).Trim()
                    ] =
                        [string]$p.Value
                }
            }


            if($null -ne $cfg.deepLinks){

                foreach(
                    $p in
                    $cfg.deepLinks.PSObject.Properties
                ){

                    $name =
                        ([string]$p.Name).Trim()


                    $team =
                        ([string]$p.Value.team).Trim()


                    $conversation =
                        ([string]$p.Value.channel).Trim()


                    if(
                        $name -and
                        $team -and
                        $conversation
                    ){

                        $deepLinks[$name] =
                            [pscustomobject]@{
                                team =
                                    $team

                                channel =
                                    $conversation
                            }
                    }
                }
            }
        }
        catch {

            throw (
                'Could not read channel-routes.json: ' +
                $_.Exception.Message
            )
        }
    }


    [pscustomobject]@{
        enabled =
            $enabled

        volume =
            $volume

        defaultSound =
            $defaultSound

        routes =
            $routes

        deepLinks =
            $deepLinks
    }
}

function Write-ChannelRoutesConfig {
    param($Config)

    $configPath =
        Join-Path `
            $script:Root `
            'channel-routes.json'


    $tempPath =
        $configPath +
        '.tmp'


    $routeObject =
        [ordered]@{}


    foreach(
        $key in
        @(
            $Config.routes.Keys |
            Sort-Object
        )
    ){

        $routeObject[
            [string]$key
        ] =
            [string]$Config.routes[$key]
    }


    $linkObject =
        [ordered]@{}


    if($null -ne $Config.deepLinks){

        foreach(
            $key in
            @(
                $Config.deepLinks.Keys |
                Sort-Object
            )
        ){

            $link =
                $Config.deepLinks[$key]


            if(
                $link -and
                $link.team -and
                $link.channel
            ){

                $linkObject[
                    [string]$key
                ] =
                    [ordered]@{
                        team =
                            [string]$link.team

                        channel =
                            [string]$link.channel
                    }
            }
        }
    }


    $output =
        [ordered]@{
            version =
                5

            enabled =
                [bool]$Config.enabled

            volume =
                [double]$Config.volume

            defaultSound =
                $Config.defaultSound

            routes =
                $routeObject

            deepLinks =
                $linkObject
        }


    $json =
        $output |
        ConvertTo-Json -Depth 10


    [IO.File]::WriteAllText(
        $tempPath,
        $json,
        (New-Object Text.UTF8Encoding($false))
    )


    Move-Item `
        -LiteralPath $tempPath `
        -Destination $configPath `
        -Force
}

function Save-ChannelAudioUpload {
    param(
        [string]$FileName,
        [string]$DataBase64,
        [string]$Prefix
    )

    if([string]::IsNullOrWhiteSpace($DataBase64)) {
        throw 'No MP3 was received.'
    }

    $name = [IO.Path]::GetFileName($FileName)

    if($name -notmatch '\.mp3$') {
        throw 'Only MP3 files are accepted.'
    }

    try {
        $bytes = [Convert]::FromBase64String($DataBase64)
    }
    catch {
        throw 'Uploaded audio was not valid base64.'
    }

    if($bytes.Length -gt 5MB) {
        throw 'MP3 exceeds 5 MB.'
    }

    $soundDir = Join-Path $script:Root 'channel-sounds'

    New-Item `
        -ItemType Directory `
        -Path $soundDir `
        -Force |
        Out-Null

    $safeName = $name -replace '[^A-Za-z0-9._ -]','_'
    $safePrefix = $Prefix -replace '[^A-Za-z0-9._-]','_'

    $destination = Join-Path `
        $soundDir `
        ("{0}__{1}" -f $safePrefix,$safeName)

    [IO.File]::WriteAllBytes($destination,$bytes)

    return $destination
}

# SHINY-SEMVER-COMPARE-V1
function Convert-ShinyVersion {
    param([string]$Text)


    if(
        [string]::IsNullOrWhiteSpace(
            $Text
        )
    ){
        return $null
    }


    $match =
        [regex]::Match(
            $Text.Trim(),
            '(?i)^v?(\d+)\.(\d+)\.(\d+)'
        )


    if(!$match.Success){
        return $null
    }


    return [version](
        "{0}.{1}.{2}" -f
        $match.Groups[1].Value,
        $match.Groups[2].Value,
        $match.Groups[3].Value
    )
}

$listener=$null
try {
    for($p=$Port;$p -lt ($Port+20);$p++){try{$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$p);$listener.Start();$Port=$p;break}catch{






function Save-ChannelAudioUpload {
    param(
        [string]$FileName,
        [string]$DataBase64,
        [string]$Prefix
    )

    if([string]::IsNullOrWhiteSpace($DataBase64)) {
        throw 'No MP3 was received.'
    }

    $name = [IO.Path]::GetFileName($FileName)

    if($name -notmatch '\.mp3$') {
        throw 'Only MP3 files are accepted.'
    }

    try {
        $bytes = [Convert]::FromBase64String($DataBase64)
    }
    catch {
        throw 'Uploaded audio was not valid base64.'
    }

    if($bytes.Length -gt 5MB) {
        throw 'MP3 exceeds 5 MB.'
    }

    $soundDir = Join-Path $script:Root 'channel-sounds'

    New-Item `
        -ItemType Directory `
        -Path $soundDir `
        -Force |
        Out-Null

    $safeName = $name -replace '[^A-Za-z0-9._ -]','_'
    $safePrefix = $Prefix -replace '[^A-Za-z0-9._-]','_'

    $destination = Join-Path `
        $soundDir `
        ("{0}__{1}" -f $safePrefix,$safeName)

    [IO.File]::WriteAllBytes($destination,$bytes)

    return $destination
}

$listener=$null}}
    if(!$listener){throw 'Could not open a local ShinySlack port.'}
    if(!(Test-Path $script:Root)){New-Item -ItemType Directory -Path $script:Root -Force|Out-Null};Set-Content (Join-Path $script:Root 'web.port') $Port -Encoding ASCII;Set-Content (Join-Path $script:Root 'web.pid') $PID -Encoding ASCII;Set-Content (Join-Path $script:Root 'web.version') $script:Build -Encoding ASCII
    if(!$NoBrowser){ Start-Process ("http://127.0.0.1:$Port/") }
    Write-WebDiag "Listening on http://127.0.0.1:$Port/"
    while(!$script:StopServer){
        $client=$null
        $rid=([guid]::NewGuid().ToString('N').Substring(0,8)).ToUpperInvariant()
        try {
            $client=$listener.AcceptTcpClient()

            $client.ReceiveTimeout = 3000
            $client.SendTimeout = 5000
            $req=Read-Request $client $rid

            if($null -eq $req){
                continue
            }
            if($req.Path -ne '/api/activity'){
                Write-WebDiag "Dispatching $($req.Method) $($req.Path)" $rid
            }

            if($req.Path -ne '/' -and $req.Path -ne '/index.html'){
                if(!$req.Headers.ContainsKey('x-shinyslack-token') -or $req.Headers['x-shinyslack-token'] -ne $script:Token){
                    Write-WebDiag 'Rejected request: bad/missing token.' $rid
                    Json-Response $client @{ok=$false;error='Forbidden'} 403
                    continue
                }
            }
            if($req.Method -eq 'GET' -and ($req.Path -eq '/' -or $req.Path -eq '/index.html')){
                Write-WebDiag 'Serving index.html' $rid
                $html=Get-Content (Join-Path $script:SourceDir 'index.html') -Raw -Encoding UTF8
                $html=$html.Replace('__TOKEN__',$script:Token)
                Send-Response $client 200 'text/html; charset=utf-8' $html
                Write-WebDiag 'index.html sent.' $rid
                continue
            }
            # SHINY-LIVE-ACTIVITY-ENDPOINT-V1
            if(
                $req.Method -eq 'GET' -and
                $req.Path -eq '/api/activity'
            ){

                $items =
                    @(
                        Get-LiveRouterActivityItems `
                            -Limit 30
                    )


                $cursor =
                    [string]$script:LiveActivityCacheKey


                $clientCursor =
                    ''


                if(
                    $req.Headers.ContainsKey(
                        'x-shinyslack-activity-cursor'
                    )
                ){

                    $clientCursor =
                        [string]$req.Headers[
                            'x-shinyslack-activity-cursor'
                        ]
                }


                if(
                    $clientCursor -and
                    $clientCursor -eq $cursor
                ){

                    Json-Response `
                        $client `
                        ([ordered]@{
                            ok =
                                $true

                            changed =
                                $false

                            cursor =
                                $cursor

                            generation =
                                [int64]$script:LiveActivityGeneration
                        })

                    continue
                }


                Json-Response `
                    $client `
                    ([ordered]@{
                        ok =
                            $true

                        changed =
                            $true

                        cursor =
                            $cursor

                        generation =
                            [int64]$script:LiveActivityGeneration

                        notifications =
                            @(
                                Convert-LiveActivitySafe `
                                    -Items $items
                            )
                    })

                continue
            }

            if($req.Method -eq 'GET' -and $req.Path -eq '/api/status'){

                Write-WebDiag 'Building status object.' $rid

                $obj =
                    Get-StatusObject `
                        -RequestId $rid


                Write-WebDiag 'STATUS JSON 1: projection starting.' $rid


                # ------------------------------
                # Notifications
                # ------------------------------

                $safeNotifications =
                    @(
                        Convert-LiveActivitySafe `
                            -Items @($obj.notifications)
                    )


                # ------------------------------
                # Channel routes
                # ------------------------------

                $safeRoutes = @()

                if(
                    $obj.channelAudio -and
                    $obj.channelAudio.routes
                ) {

                    foreach(
                        $r in
                        @($obj.channelAudio.routes)
                    ) {

                        if($null -eq $r) {
                            continue
                        }

                        $safeRoutes +=
                            [ordered]@{
                                channel =
                                    [string]$r.channel

                                sound =
                                    [string]$r.sound

                                # SHINY-PRESET-STATE-SAFE-ROUTE-V1
                                presetId =
                                    [string]$r.presetId

                                linked =
                                    [bool]$r.linked

                                team =
                                    [string]$r.team

                                channelId =
                                    [string]$r.channelId
                            }
                    }
                }


                Write-WebDiag `
                    "STATUS JSON 2: projection complete notifications=$($safeNotifications.Count) routes=$($safeRoutes.Count)" `
                    $rid


                # ------------------------------
                # Primitive-only payload
                # ------------------------------

                $payload =
                    [ordered]@{
                        ok             = [bool]$obj.ok
                        build          = [string]$obj.build
                        installed      = [bool]$obj.installed
                        slackRunning   = [bool]$obj.slackRunning
                        cachePresent   = [bool]$obj.cachePresent
                        health         = [string]$obj.health
                        watcherRunning = [bool]$obj.watcherRunning
                        watcherDetail  = [string]$obj.watcherDetail
                        ffmpeg         = [bool]$obj.ffmpeg
                        log            = [string]$obj.log
                        notifications  = @($safeNotifications)
                        activityCursor = [string]$script:LiveActivityCacheKey
                        activityGeneration = [int64]$script:LiveActivityGeneration
                        agentBuild     = [string]$obj.agentBuild

                        channelAudio =
                            [ordered]@{
                                routerRunning =
                                    [bool]$obj.channelAudio.routerRunning

                                enabled =
                                    [bool]$obj.channelAudio.enabled

                                volume =
                                    [double]$obj.channelAudio.volume

                                defaultSound =
                                    [string]$obj.channelAudio.defaultSound

                                # SHINY-PRESET-STATE-SAFE-DEFAULT-V1
                                defaultPresetId =
                                    [string]$obj.channelAudio.defaultPresetId

                                routes =
                                    @($safeRoutes)

                                lastDetected =
                                    [string]$obj.channelAudio.lastDetected
                            }
                    }


                if(
                    $obj.PSObject.Properties[
                        'soundOwnership'
                    ]
                ) {

                    $payload['soundOwnership'] =
                        [ordered]@{
                            mode =
                                [string]$obj.soundOwnership.mode

                            transition =
                                [bool]$obj.soundOwnership.transition

                            nativeSuppressed =
                                [bool]$obj.soundOwnership.nativeSuppressed

                            routerRunning =
                                [bool]$obj.soundOwnership.routerRunning

                            routerAudioEnabled =
                                [bool]$obj.soundOwnership.routerAudioEnabled

                            volume =
                                [double]$obj.soundOwnership.volume

                            defaultReady =
                                [bool]$obj.soundOwnership.defaultReady

                            guardFresh =
                                [bool]$obj.soundOwnership.guardFresh

                            guardState =
                                [string]$obj.soundOwnership.guardState

                            guardMessage =
                                [string]$obj.soundOwnership.guardMessage

                            guardRouterHealthy =
                                [bool]$obj.soundOwnership.guardRouterHealthy

                            risk =
                                [bool]$obj.soundOwnership.risk

                            audioIntentionallyMuted =
                                [bool]$obj.soundOwnership.audioIntentionallyMuted

                            lastError =
                                [string]$obj.soundOwnership.lastError
                        }
                }


                if(
                    $obj.PSObject.Properties[
                        'alertSettings'
                    ]
                ) {

                    $payload['alertSettings'] =
                        [ordered]@{
                            autoDismiss =
                                [bool]$obj.alertSettings.autoDismiss

                            autoDismissSeconds =
                                [int]$obj.alertSettings.autoDismissSeconds
                        }
                }


                # ------------------------------
                # Serialize
                # ------------------------------

                $json =
                    $payload |
                    ConvertTo-Json `
                        -Depth 5 `
                        -Compress


                Write-WebDiag `
                    "STATUS JSON 3: serialized chars=$($json.Length)" `
                    $rid


                # ------------------------------
                # Write bytes
                # ------------------------------

                Send-Response `
                    $client `
                    200 `
                    'application/json; charset=utf-8' `
                    $json


                Write-WebDiag `
                    'STATUS JSON 4: socket write complete.' `
                    $rid


                Write-WebDiag `
                    'Status response sent.' `
                    $rid


                continue
            }

            if($req.Method -eq 'GET' -and $req.Path -eq '/api/update/check'){
                try {
                    Write-WebDiag 'Checking GitHub for ShinySlack updates.' $rid

                    $versionPath = Join-Path $script:SourceDir 'version.txt'
                    $currentVersion = 'v2.7.5'

                    if(Test-Path -LiteralPath $versionPath) {
                        $readVersion = (
                            Get-Content `
                                -LiteralPath $versionPath `
                                -Raw `
                                -Encoding UTF8
                        ).Trim()

                        if($readVersion) {
                            $currentVersion = $readVersion
                        }
                    }

                                                            $headers = @{
                        'User-Agent'           = 'ShinySlack'
                        'Accept'               = 'application/vnd.github+json'
                        'X-GitHub-Api-Version' = '2022-11-28'
                    }

                    $oldProtocol =
                        [Net.ServicePointManager]::SecurityProtocol

                    try {
                        [Net.ServicePointManager]::SecurityProtocol =
                            $oldProtocol -bor
                            [Net.SecurityProtocolType]::Tls12

                        $releaseResponse =
                            Invoke-RestMethod `
                                -Uri 'https://api.github.com/repos/The-Pr0grammer/ShinySlack/releases?per_page=20' `
                                -Headers $headers `
                                -Method Get `
                                -TimeoutSec 10
                    }
                    finally {
                        [Net.ServicePointManager]::SecurityProtocol =
                            $oldProtocol
                    }

                    # Windows PowerShell 5.1 can preserve a returned
                    # JSON array as a nested array object. Flatten it
                    # explicitly instead of relying on pipeline behavior.
                    $latest = $null

                    $releaseQueue =
                        New-Object System.Collections.Queue

                    $releaseQueue.Enqueue(
                        $releaseResponse
                    )

                    while(
                        $releaseQueue.Count -gt 0 -and
                        !$latest
                    ) {
                        $item =
                            $releaseQueue.Dequeue()

                        if($null -eq $item) {
                            continue
                        }

                        if($item -is [System.Array]) {

                            foreach($nested in $item) {
                                $releaseQueue.Enqueue(
                                    $nested
                                )
                            }

                            continue
                        }

                        if(-not [bool]$item.draft) {
                            $latest = $item
                        }
                    }
if(!$latest) {
                        throw 'GitHub returned no published ShinySlack releases.'
                    }

                    $latestVersion = [string]$latest.tag_name
                    # SHINY-SEMVER-UPDATE-DECISION-V1
                    $currentComparable =
                        Convert-ShinyVersion `
                            $currentVersion

                    $latestComparable =
                        Convert-ShinyVersion `
                            $latestVersion

                    $updateAvailable =
                        if(
                            $currentComparable -and
                            $latestComparable
                        ){
                            $latestComparable -gt
                            $currentComparable
                        }
                        else {
                            $latestVersion -ne
                            $currentVersion
                        }

                    Json-Response $client @{
                        ok              = $true
                        currentVersion  = $currentVersion
                        latestVersion   = $latestVersion
                        updateAvailable = $updateAvailable
                        releaseUrl      = [string]$latest.html_url
                        prerelease      = [bool]$latest.prerelease
                    }

                    Write-WebDiag `
                        "Update check complete. installed=$currentVersion latest=$latestVersion" `
                        $rid
                }
                catch {
                    Write-WebException $_ $rid 'Update check failed'

                    Json-Response $client @{
                        ok    = $false
                        error = "Could not check for updates: $($_.Exception.Message)"
                    } 500
                }

                continue
            }

            if($req.Method -eq 'GET' -and $req.Path -like '/api/op/*'){
                try{
                    $id=$req.Path.Substring('/api/op/'.Length)
                    Write-WebDiag "Reading operation $id" $rid
                    Json-Response $client (Get-OperationObject $id)
                }catch{
                    Write-WebException $_ $rid 'Operation status route failed'
                    Json-Response $client @{ok=$false;error=$_.Exception.Message} 404
                }
                continue
            }
            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/sound-ownership'
            ){
                try{
                    $j=$req.Body|ConvertFrom-Json
                    $mode=[string]$j.mode

                    if(
                        $mode -notin
                        @(
                            'RouterExclusive',
                            'NativeFallback'
                        )
                    ){
                        throw 'Invalid sound ownership mode.'
                    }

                    $scriptPath=
                        Join-Path `
                            $script:Root `
                            'Set-SoundOwnership.ps1'

                    if(!(Test-Path $scriptPath)){
                        throw 'Set-SoundOwnership.ps1 is missing.'
                    }

                    $id=
                        Start-AsyncOperation `
                            -Script $scriptPath `
                            -Arguments @(
                                '-Mode',$mode,
                                '-Reason','dashboard'
                            ) `
                            -RequestId $rid

                    Json-Response `
                        $client `
                        @{
                            ok=$true
                            operationId=$id
                        } `
                        202
                }catch{
                    Write-WebException `
                        $_ `
                        $rid `
                        'Sound ownership transition failed'

                    Json-Response `
                        $client `
                        @{
                            ok=$false
                            error=$_.Exception.Message
                        } `
                        500
                }

                continue
            }

            if($req.Method -eq 'POST' -and $req.Path -eq '/api/apply'){
                try{
                    Write-WebDiag "Apply entered. JSON chars=$($req.Body.Length)" $rid
                    $j=$req.Body|ConvertFrom-Json
                    Write-WebDiag 'Apply JSON parsed.' $rid
                    if(!$j.dataBase64){throw 'No MP3 was received.'}
                    $b64=[string]$j.dataBase64
                    Write-WebDiag "Decoding base64 chars=$($b64.Length)" $rid
                    $raw=[Convert]::FromBase64String($b64)
                    Write-WebDiag "Decoded MP3 bytes=$($raw.Length)" $rid
                    if($raw.Length -gt 5MB){throw 'MP3 exceeds 5 MB.'}
                    $name=[IO.Path]::GetFileName([string]$j.fileName)
                    if($name -notmatch '\.mp3$'){throw 'Only MP3 files are accepted.'}
                    $safe=($name -replace '[^A-Za-z0-9._ -]','_')
                    $tmpDir=Join-Path $env:TEMP 'ShinySlackWeb'
                    New-Item -ItemType Directory -Path $tmpDir -Force|Out-Null
                    $tmp=Join-Path $tmpDir (([guid]::NewGuid().ToString('N'))+'_'+$safe)
                    Write-WebDiag "Writing uploaded MP3 to $tmp" $rid
                    [IO.File]::WriteAllBytes($tmp,$raw)
                    Write-WebDiag 'Uploaded MP3 written.' $rid

                    $installed=Test-Path (Join-Path $script:Root 'Set-ShinySlackSound.ps1')
                    $sourceIsRoot=([IO.Path]::GetFullPath($script:SourceDir).TrimEnd('\') -eq [IO.Path]::GetFullPath($script:Root).TrimEnd('\'))
                    if($installed -and $sourceIsRoot){
                        $opScript=Join-Path $script:Root 'Set-ShinySlackSound.ps1';$args=@($tmp)
                        Write-WebDiag "Using installed Set-ShinySlackSound.ps1" $rid
                    }else{
                        $opScript=Join-Path $script:SourceDir 'Install-ShinySlack.ps1';$args=@('-Mp3Path',$tmp)
                        Write-WebDiag "Using first-install Install-ShinySlack.ps1" $rid
                    }
                    Write-WebDiag 'Persisting web files.' $rid
                    Persist-WebFiles
                    Write-WebDiag 'Persist-WebFiles complete.' $rid
                    $id=Start-AsyncOperation -Script $opScript -Arguments $args -CleanupPath $tmp -RequestId $rid
                    Write-WebDiag "Apply queued operation=$id; sending HTTP 202." $rid
                    Json-Response $client @{ok=$true;operationId=$id} 202
                    Write-WebDiag 'Apply HTTP 202 sent.' $rid
                }catch{
                    Write-WebException $_ $rid 'Apply route failed'
                    try{Json-Response $client @{ok=$false;error=$_.Exception.Message} 500}catch{Write-WebException $_ $rid 'Failed to send Apply error response'}
                }
                continue
            }


            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/alerts/settings'
            ) {

                try {

                    $body =
                        $req.Body |
                        ConvertFrom-Json


                    if($null -eq $body.autoDismiss) {
                        throw 'autoDismiss is required.'
                    }


                    $settings =
                        Set-PersistentAlertSettings `
                            -AutoDismiss ([bool]$body.autoDismiss)


                    Json-Response $client @{
                        ok = $true
                        settings = $settings
                    }
                }
                catch {

                    Write-WebException `
                        $_ `
                        $rid `
                        'Alert settings failed'


                    Json-Response $client @{
                        ok = $false
                        error = $_.Exception.Message
                    } 500
                }


                continue
            }

            # SHINY-AUDIO-CONTROLS-API-V2
            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/channel/audio'
            ){
                try {

                    $j =
                        $req.Body |
                        ConvertFrom-Json


                    $cfg =
                        Read-ChannelRoutesConfig


                    if($null -ne $j.enabled){

                        $cfg.enabled =
                            [bool]$j.enabled
                    }


                    if($null -ne $j.volume){

                        $newVolume =
                            [double]$j.volume


                        if($newVolume -lt 0){
                            $newVolume = 0
                        }


                        if($newVolume -gt 1){
                            $newVolume = 1
                        }


                        $cfg.volume =
                            $newVolume
                    }


                    Write-ChannelRoutesConfig `
                        $cfg


                    Json-Response $client @{
                        ok      = $true
                        enabled = [bool]$cfg.enabled
                        volume  = [double]$cfg.volume
                    }


                    Write-WebDiag (
                        "Audio controls updated enabled={0} volume={1}" -f
                        [bool]$cfg.enabled,
                        [double]$cfg.volume
                    ) $rid
                }
                catch {

                    Write-WebException `
                        $_ `
                        $rid `
                        'Audio controls update failed'


                    Json-Response $client @{
                        ok    = $false
                        error = $_.Exception.Message
                    } 500
                }


                continue
            }

            # SHINY-DEEP-LINK-API-V1
            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/channel/link'
            ){
                try {

                    $j =
                        $req.Body |
                        ConvertFrom-Json


                    $channel =
                        ([string]$j.channel).Trim()


                    if($channel.StartsWith('#')){

                        $channel =
                            $channel.Substring(1)
                    }


                    if(
                        [string]::IsNullOrWhiteSpace(
                            $channel
                        )
                    ){

                        throw 'Channel cannot be empty.'
                    }


                    $url =
                        ([string]$j.url).Trim()


                    $cfg =
                        Read-ChannelRoutesConfig


                    # Blank URL = unlink.
                    if(
                        [string]::IsNullOrWhiteSpace(
                            $url
                        )
                    ){

                        if(
                            $cfg.deepLinks.ContainsKey(
                                $channel
                            )
                        ){

                            $cfg.deepLinks.Remove(
                                $channel
                            )
                        }


                        Write-ChannelRoutesConfig `
                            $cfg


                        Json-Response $client @{
                            ok      = $true
                            channel = $channel
                            linked  = $false
                        }


                        continue
                    }


                    $team =
                        ''

                    $conversation =
                        ''


                    # Browser client URL:
                    # https://app.slack.com/client/T123/C123
                    if(
                        $url -match
                        '^https?://app\.slack\.com/client/(?<team>[TE][A-Z0-9]+)/(?<conversation>[CDG][A-Z0-9]+)'
                    ){

                        $team =
                            [string]$Matches.team

                        $conversation =
                            [string]$Matches.conversation
                    }

                    # Native URI:
                    # slack://channel?team=T123&id=C123
                    elseif(
                        $url -match
                        '^slack://channel\?team=(?<team>[TE][A-Z0-9]+)&id=(?<conversation>[CDG][A-Z0-9]+)'
                    ){

                        $team =
                            [string]$Matches.team

                        $conversation =
                            [string]$Matches.conversation
                    }

                    # Convenience:
                    # T123/C123
                    elseif(
                        $url -match
                        '^(?<team>[TE][A-Z0-9]+)/(?<conversation>[CDG][A-Z0-9]+)$'
                    ){

                        $team =
                            [string]$Matches.team

                        $conversation =
                            [string]$Matches.conversation
                    }
                    else {

                        throw (
                            'Paste a Slack browser URL like ' +
                            'https://app.slack.com/client/T123/C123'
                        )
                    }


                    $cfg.deepLinks[$channel] =
                        [pscustomobject]@{
                            team =
                                $team

                            channel =
                                $conversation
                        }


                    Write-ChannelRoutesConfig `
                        $cfg


                    Json-Response $client @{
                        ok        = $true
                        channel   = $channel
                        linked    = $true
                        team      = $team
                        channelId = $conversation
                        uri       = (
                            'slack://channel?team={0}&id={1}' -f
                            $team,
                            $conversation
                        )
                    }


                    Write-WebDiag (
                        'Deep link configured: #{0} -> {1}/{2}' -f
                        $channel,
                        $team,
                        $conversation
                    ) $rid
                }
                catch {

                    Write-WebException `
                        $_ `
                        $rid `
                        'Channel deep-link update failed'


                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }

            # SHINY-DEEPLINK-HISTORY-API-V1

            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/channel/deeplink'
            ){
                try {

                    $j =
                        $req.Body |
                        ConvertFrom-Json


                    $channel =
                        ([string]$j.channel).Trim()


                    if($channel.StartsWith('#')){
                        $channel = $channel.Substring(1)
                    }


                    if(!$channel){
                        throw 'Channel is required.'
                    }


                    $channelId =
                        ([string]$j.channelId).Trim()


                    $cfg =
                        Read-ChannelRoutesConfig


                    # Blank ID = unlink.
                    if(!$channelId){

                        if(
                            $cfg.deepLinks.ContainsKey(
                                $channel
                            )
                        ){

                            $cfg.deepLinks.Remove(
                                $channel
                            )
                        }


                        Write-ChannelRoutesConfig `
                            $cfg


                                            # SHINY-DEEPLINK-READBACK-V1
                    # Never claim success until the saved mapping
                    # survives a complete JSON write/read cycle.

                    $verifyCfg =
                        Read-ChannelRoutesConfig


                    if(
                        !$verifyCfg.deepLinks.ContainsKey(
                            $channel
                        )
                    ){

                        throw (
                            'Deep link write verification failed: ' +
                            'channel mapping missing after reload.'
                        )
                    }


                    $verifyLink =
                        $verifyCfg.deepLinks[$channel]


                    if(
                        [string]$verifyLink.team -ne
                        [string]$teamId -or

                        [string]$verifyLink.channel -ne
                        [string]$channelId
                    ){

                        throw (
                            'Deep link write verification failed: ' +
                            'saved IDs did not match.'
                        )
                    }


Json-Response $client @{
                            ok =
                                $true

                            linked =
                                $false

                            channel =
                                $channel
                        }


                        continue
                    }


                    if(
                        $channelId -notmatch
                        '^[CDG][A-Z0-9]+$'
                    ){

                        throw (
                            'Channel ID should look like CXXXXXXXXXX.'
                        )
                    }


                    $teamId =
                        ([string]$j.teamId).Trim()


                    if(!$teamId){

                        $workspaces =
                            @(
                                Get-SlackDesktopWorkspaces
                            )


                        if($workspaces.Count -eq 1){

                            $teamId =
                                [string]$workspaces[0].teamId
                        }
                        else {

                            throw (
                                'Multiple Slack workspaces detected; choose a workspace.'
                            )
                        }
                    }


                    if(
                        $teamId -notmatch
                        '^[TE][A-Z0-9]+$'
                    ){

                        throw 'Invalid workspace/team ID.'
                    }


                    $cfg.deepLinks[$channel] =
                        [pscustomobject]@{
                            team =
                                $teamId

                            channel =
                                $channelId
                        }


                    Write-ChannelRoutesConfig `
                        $cfg


                    Json-Response $client @{
                        ok =
                            $true

                        linked =
                            $true

                        channel =
                            $channel

                        team =
                            $teamId

                        channelId =
                            $channelId
                    }


                    continue
                }
                catch {

                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }


            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/channel/open'
            ){
                try {

                    $j =
                        $req.Body |
                        ConvertFrom-Json


                    $channel =
                        ([string]$j.channel).Trim()


                    if($channel.StartsWith('#')){
                        $channel = $channel.Substring(1)
                    }


                    $cfg =
                        Read-ChannelRoutesConfig


                    if(
                        $channel -and
                        $cfg.deepLinks.ContainsKey(
                            $channel
                        )
                    ){

                        $link =
                            $cfg.deepLinks[$channel]


                        $uri =
                            'slack://channel?team={0}&id={1}' -f
                            [Uri]::EscapeDataString(
                                [string]$link.team
                            ),
                            [Uri]::EscapeDataString(
                                [string]$link.channel
                            )


                        Start-Process `
                            $uri |
                        Out-Null


                        Json-Response $client @{
                            ok =
                                $true

                            linked =
                                $true
                        }
                    }
                    else {

                        Start-Process `
                            'slack://open' |
                        Out-Null


                        Json-Response $client @{
                            ok =
                                $true

                            linked =
                                $false
                        }
                    }
                }
                catch {

                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }


            # SHINY-PRIVACY-HISTORY-ENDPOINT-GUARD-275-V1
            if(
                $req.Path -like '/api/history/*' -and
                !$script:HistoryFeatureEnabled
            ){
                Json-Response $client @{
                    ok =
                        $false

                    error =
                        'Notification history is disabled in v2.7.5 pending the v2.8 privacy design.'
                } 409

                continue
            }

            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/history/connect'
            ){
                try {

                    $j =
                        $req.Body |
                        ConvertFrom-Json


                    $token =
                        ([string]$j.token).Trim()


                    if(!$token){
                        throw 'Slack user token is required.'
                    }


                    $headers =
                        @{
                            Authorization =
                                "Bearer $token"

                            Accept =
                                'application/json'

                            'User-Agent' =
                                'ShinySlack-History'
                        }


                    $authTest =
                        Invoke-RestMethod `
                            -Uri 'https://slack.com/api/auth.test' `
                            -Headers $headers `
                            -Method Post `
                            -TimeoutSec 15


                    if(!$authTest.ok){

                        throw (
                            'Slack auth failed: ' +
                            $authTest.error
                        )
                    }


                    $protected =
                        Protect-ShinySecret `
                            $token


                    $authPath =
                        Join-Path `
                            $script:Root `
                            'history-auth.json'


                    [ordered]@{
                        protectedToken =
                            $protected

                        teamId =
                            [string]$authTest.team_id

                        teamName =
                            [string]$authTest.team

                        userId =
                            [string]$authTest.user_id

                        userName =
                            [string]$authTest.user

                        connectedAt =
                            (Get-Date).ToString('o')
                    } |
                    ConvertTo-Json -Depth 5 |
                    Set-Content `
                        -LiteralPath $authPath `
                        -Encoding UTF8


                    $statePath =
                        Join-Path `
                            $script:Root `
                            'history-backfill-state.json'


                    if(!(Test-Path -LiteralPath $statePath)){

                        [ordered]@{
                            lastSyncEpoch =
                                [double](
                                    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -
                                    86400
                                )
                        } |
                        ConvertTo-Json |
                        Set-Content `
                            -LiteralPath $statePath `
                            -Encoding UTF8
                    }


                    Start-HistoryBackfillOnce


                    Json-Response $client @{
                        ok =
                            $true

                        teamId =
                            [string]$authTest.team_id

                        teamName =
                            [string]$authTest.team

                        userName =
                            [string]$authTest.user
                    }
                }
                catch {

                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }


            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/history/disconnect'
            ){

                Remove-Item `
                    (Join-Path $script:Root 'history-auth.json') `
                    -Force `
                    -ErrorAction SilentlyContinue


                Remove-Item `
                    (Join-Path $script:Root 'history-backfill-status.json') `
                    -Force `
                    -ErrorAction SilentlyContinue


                Json-Response $client @{
                    ok = $true
                }


                continue
            }


            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/history/backfill'
            ){
                try {

                    Start-HistoryBackfillOnce


                    Json-Response $client @{
                        ok = $true
                    }
                }
                catch {

                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }

            # SHINY-SOUND-PRESETS-API-V1
            if(
                $req.Method -eq 'GET' -and
                $req.Path -eq '/api/channel/presets'
            ){
                try {

                    $public =
                        @(
                            Get-SoundPresets |
                            ForEach-Object {
                                [ordered]@{
                                    id =
                                        [string]$_.id

                                    name =
                                        [string]$_.name

                                    fileName =
                                        [string]$_.fileName
                                }
                            }
                        )


                    Json-Response $client @{
                        ok =
                            $true

                        presets =
                            @($public)
                    }
                }
                catch {

                    Write-WebException `
                        $_ `
                        $rid `
                        'Preset library read failed'


                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }


            if(
                $req.Method -eq 'POST' -and
                $req.Path -eq '/api/channel/preset'
            ){
                try {

                    $j =
                        $req.Body |
                        ConvertFrom-Json


                    $preset =
                        Resolve-SoundPreset `
                            -PresetId ([string]$j.presetId)


                    $target =
                        ([string]$j.target).Trim().ToLowerInvariant()


                    $cfg =
                        Read-ChannelRoutesConfig


                    if($target -eq 'default'){

                        $cfg.defaultSound =
                            [string]$preset.path


                        Write-ChannelRoutesConfig `
                            $cfg


                        Json-Response $client @{
                            ok =
                                $true

                            target =
                                'default'

                            presetId =
                                [string]$preset.id

                            presetName =
                                [string]$preset.name

                            sound =
                                [string]$preset.fileName
                        }


                        Write-WebDiag (
                            'Default preset selected: {0}' -f
                            [string]$preset.name
                        ) $rid


                        continue
                    }


                    if($target -ne 'channel'){
                        throw 'Preset target must be default or channel.'
                    }


                    $channel =
                        ([string]$j.channel).Trim()


                    if($channel.StartsWith('#')){
                        $channel =
                            $channel.Substring(1)
                    }


                    if(
                        [string]::IsNullOrWhiteSpace(
                            $channel
                        )
                    ){
                        throw 'Channel is required for a channel preset.'
                    }


                    $cfg.routes[$channel] =
                        [string]$preset.path


                    Write-ChannelRoutesConfig `
                        $cfg


                    Json-Response $client @{
                        ok =
                            $true

                        target =
                            'channel'

                        channel =
                            $channel

                        presetId =
                            [string]$preset.id

                        presetName =
                            [string]$preset.name

                        sound =
                            [string]$preset.fileName
                    }


                    Write-WebDiag (
                        'Channel preset selected: #{0} -> {1}' -f
                        $channel,
                        [string]$preset.name
                    ) $rid
                }
                catch {

                    Write-WebException `
                        $_ `
                        $rid `
                        'Preset selection failed'


                    Json-Response $client @{
                        ok =
                            $false

                        error =
                            $_.Exception.Message
                    } 500
                }


                continue
            }

            if($req.Method -eq 'POST' -and $req.Path -eq '/api/channel/default'){
                try {
                    $j = $req.Body | ConvertFrom-Json

                    $saved = Save-ChannelAudioUpload `
                        -FileName ([string]$j.fileName) `
                        -DataBase64 ([string]$j.dataBase64) `
                        -Prefix 'DEFAULT'

                    $cfg = Read-ChannelRoutesConfig
                    $cfg.defaultSound = $saved

                    Write-ChannelRoutesConfig $cfg

                    Json-Response $client @{
                        ok = $true
                        sound = [IO.Path]::GetFileName($saved)
                    }

                    Write-WebDiag "Default channel-router sound updated." $rid
                }
                catch {
                    Write-WebException $_ $rid 'Default channel sound route failed'
                    Json-Response $client @{
                        ok = $false
                        error = $_.Exception.Message
                    } 500
                }

                continue
            }

            if($req.Method -eq 'POST' -and $req.Path -eq '/api/channel/route'){
                try {
                    $j = $req.Body | ConvertFrom-Json

                    $channel = [string]$j.channel
                    $channel = $channel.Trim()

                    if($channel.StartsWith('#')) {
                        $channel = $channel.Substring(1)
                    }

                    if([string]::IsNullOrWhiteSpace($channel)) {
                        throw 'Channel cannot be empty.'
                    }

                    $saved = Save-ChannelAudioUpload `
                        -FileName ([string]$j.fileName) `
                        -DataBase64 ([string]$j.dataBase64) `
                        -Prefix $channel

                    $cfg = Read-ChannelRoutesConfig
                    $cfg.routes[$channel] = $saved

                    Write-ChannelRoutesConfig $cfg

                    Json-Response $client @{
                        ok = $true
                        channel = $channel
                        sound = [IO.Path]::GetFileName($saved)
                    }

                    Write-WebDiag "Channel route updated: #$channel" $rid
                }
                catch {
                    Write-WebException $_ $rid 'Channel route update failed'
                    Json-Response $client @{
                        ok = $false
                        error = $_.Exception.Message
                    } 500
                }

                continue
            }

            if($req.Method -eq 'POST' -and $req.Path -eq '/api/channel/remove'){
                try {
                    $j = $req.Body | ConvertFrom-Json

                    $channel = [string]$j.channel
                    $channel = $channel.Trim()

                    if($channel.StartsWith('#')) {
                        $channel = $channel.Substring(1)
                    }

                    if([string]::IsNullOrWhiteSpace($channel)) {
                        throw 'Channel cannot be empty.'
                    }

                    $cfg = Read-ChannelRoutesConfig

                    if($cfg.routes.ContainsKey($channel)) {
                        $cfg.routes.Remove($channel)
                    }

                    # SHINY-DEEP-LINK-REMOVE-V1
                    if($cfg.deepLinks.ContainsKey($channel)) {
                        $cfg.deepLinks.Remove($channel)
                    }

                    Write-ChannelRoutesConfig $cfg

                    Json-Response $client @{
                        ok = $true
                        channel = $channel
                    }

                    Write-WebDiag "Channel route removed: #$channel" $rid
                }
                catch {
                    Write-WebException $_ $rid 'Channel route removal failed'
                    Json-Response $client @{
                        ok = $false
                        error = $_.Exception.Message
                    } 500
                }

                continue
            }
            if($req.Method -eq 'POST' -and $req.Path -eq '/api/repair'){
                try{
                    $s=Join-Path $script:Root 'Repair-ShinySlack.ps1'
                    if(!(Test-Path $s)){throw 'ShinySlack is not installed yet. Choose an MP3 and click Apply Sound first.'}
                    $id=Start-AsyncOperation -Script $s -RequestId $rid
                    Json-Response $client @{ok=$true;operationId=$id} 202
                }catch{Write-WebException $_ $rid 'Repair route failed';Json-Response $client @{ok=$false;error=$_.Exception.Message} 500}
                continue
            }
            if($req.Method -eq 'POST' -and $req.Path -eq '/api/uninstall'){
                try{
                    $s=Join-Path $script:Root 'Uninstall-ShinySlack.ps1'
                    if(!(Test-Path $s)){throw 'ShinySlack is not installed.'}
                    $id=Start-AsyncOperation -Script $s -RequestId $rid
                    Json-Response $client @{ok=$true;operationId=$id} 202
                }catch{Write-WebException $_ $rid 'Uninstall route failed';Json-Response $client @{ok=$false;error=$_.Exception.Message} 500}
                continue
            }
            if($req.Method -eq 'POST' -and $req.Path -eq '/api/shutdown'){
                Write-WebDiag 'Shutdown requested.' $rid
                Json-Response $client @{ok=$true}
                $script:StopServer=$true
                continue
            }
            Write-WebDiag "No route matched $($req.Method) $($req.Path)" $rid
            Json-Response $client @{ok=$false;error='Not found'} 404
        } catch {
            Write-WebException $_ $rid 'Top-level request failure'
            if($client){ try{Json-Response $client @{ok=$false;error=$_.Exception.Message} 500}catch{Write-WebException $_ $rid 'Could not send top-level error response'} }
        } finally {
            if($client){ try{$client.Close();Write-WebDiag 'Client closed.' $rid}catch{} }
        }
    }
} catch {
    Write-WebException $_ 'SERVER' 'Fatal server exception'
    throw
} finally {
    Write-WebDiag 'Server shutting down.'
    if($listener){$listener.Stop()};Remove-Item (Join-Path $script:Root 'web.port') -Force -ErrorAction SilentlyContinue;Remove-Item (Join-Path $script:Root 'web.pid') -Force -ErrorAction SilentlyContinue
    if($hasMutex){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()
}
