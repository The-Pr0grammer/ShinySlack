param(
    [switch]$Once,
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'

# SHINY-PRIVACY-HISTORY-WORKER-DISABLED-275-V1
Write-Host 'ShinySlack notification history is disabled in v2.7.5.'
Write-Host 'The worker will be redesigned under the v2.8 privacy model.'
exit 0

$root =
    Join-Path `
        $env:LOCALAPPDATA `
        'ShinySlack'


$authPath =
    Join-Path `
        $root `
        'history-auth.json'


$statePath =
    Join-Path `
        $root `
        'history-backfill-state.json'


$statusPath =
    Join-Path `
        $root `
        'history-backfill-status.json'


$configPath =
    Join-Path `
        $root `
        'channel-routes.json'


$ledgerPath =
    Join-Path `
        $root `
        'notification-ledger.jsonl'


$logPath =
    Join-Path `
        $root `
        'history-backfill.log'


# Only one recovery worker per Windows user.
$mutex =
    New-Object `
        Threading.Mutex(
            $false,
            'Local\ShinySlackHistoryBackfillV1'
        )


$hasMutex =
    $false


try {

    $hasMutex =
        $mutex.WaitOne(
            0,
            $false
        )


    if(!$hasMutex){
        exit 0
    }


    function Log {
        param([string]$Message)

        try {

            Add-Content `
                -LiteralPath $logPath `
                -Value (
                    "{0} {1}" -f
                    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),
                    $Message
                ) `
                -Encoding UTF8
        }
        catch {}
    }


    function Write-Status {
        param(
            [bool]$Connected,
            [string]$TeamId = '',
            [string]$TeamName = '',
            [string]$UserName = '',
            [int]$Recovered = 0,
            [string]$ErrorMessage = '',
            [double]$LastSyncEpoch = 0
        )

        $obj =
            [ordered]@{
                connected =
                    $Connected

                teamId =
                    $TeamId

                teamName =
                    $TeamName

                userName =
                    $UserName

                lastRun =
                    (Get-Date).ToString('o')

                recoveredLastRun =
                    $Recovered

                lastError =
                    $ErrorMessage

                lastSyncEpoch =
                    $LastSyncEpoch
            }


        $obj |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $statusPath `
                -Encoding UTF8
    }


    function Unprotect-Token {
        param([string]$Protected)

        if(
            [string]::IsNullOrWhiteSpace(
                $Protected
            )
        ){
            return ''
        }


        $secure =
            ConvertTo-SecureString `
                $Protected


        $ptr =
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                $secure
            )


        try {

            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                $ptr
            )
        }
        finally {

            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
                $ptr
            )
        }
    }


    function Get-PropertyValue {
        param(
            $Object,
            [string]$Name
        )

        if($null -eq $Object){
            return $null
        }


        $property =
            $Object.PSObject.Properties |
            Where-Object {
                $_.Name -eq $Name
            } |
            Select-Object -First 1


        if($property){
            return $property.Value
        }


        return $null
    }


    function Trim-Ledger {

        if(!(Test-Path -LiteralPath $ledgerPath)){
            return
        }


        try {

            $info =
                Get-Item `
                    -LiteralPath $ledgerPath


            if($info.Length -lt 5MB){
                return
            }


            $tail =
                @(
                    Get-Content `
                        -LiteralPath $ledgerPath `
                        -Tail 5000 `
                        -Encoding UTF8
                )


            $temp =
                $ledgerPath + '.trim'


            $tail |
                Set-Content `
                    -LiteralPath $temp `
                    -Encoding UTF8


            Move-Item `
                -LiteralPath $temp `
                -Destination $ledgerPath `
                -Force
        }
        catch {

            Log (
                'LEDGER_TRIM_ERROR ' +
                $_.Exception.Message
            )
        }
    }


    function Get-KnownKeys {

        $known =
            New-Object `
                'System.Collections.Generic.HashSet[string]'


        if(!(Test-Path -LiteralPath $ledgerPath)){
            return $known
        }


        foreach(
            $line in
            @(
                Get-Content `
                    -LiteralPath $ledgerPath `
                    -Tail 10000 `
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


                if($obj.eventKey){

                    [void]$known.Add(
                        [string]$obj.eventKey
                    )
                }
            }
            catch {}
        }


        return $known
    }


    function Append-RecoveredEvent {
        param(
            [string]$TeamId,
            [string]$ChannelId,
            [string]$ChannelName,
            [string]$SlackTs,
            [string]$Sound,
            $Known
        )

        $key =
            "slack|{0}|{1}|{2}" -f
            $TeamId,
            $ChannelId,
            $SlackTs


        if($Known.Contains($key)){
            return $false
        }


        $seconds =
            [double]$SlackTs


        $whole =
            [int64][Math]::Floor(
                $seconds
            )


        $fraction =
            $seconds - $whole


        $when =
            [DateTimeOffset]::FromUnixTimeSeconds(
                $whole
            ).UtcDateTime.AddSeconds(
                $fraction
            ).ToString('o')


        $source =
            if($ChannelName.StartsWith('#')){
                $ChannelName
            }
            else {
                '#' + $ChannelName
            }


        $entry =
            [ordered]@{
                schema =
                    1

                time =
                    $when

                source =
                    $source

                message =
                    'Recovered channel activity'

                sound =
                    $Sound

                backend =
                    'SLACK_API'

                origin =
                    'recovered'

                recovered =
                    $true

                teamId =
                    $TeamId

                channelId =
                    $ChannelId

                slackTs =
                    $SlackTs

                eventKey =
                    $key
            }


        Add-Content `
            -LiteralPath $ledgerPath `
            -Value (
                $entry |
                ConvertTo-Json -Compress
            ) `
            -Encoding UTF8


        [void]$Known.Add(
            $key
        )


        return $true
    }


    function Invoke-SlackHistory {
        param(
            [string]$Token,
            [string]$ChannelId,
            [double]$Oldest,
            [string]$TeamId,
            [string]$ChannelName,
            [string]$Sound,
            $Known
        )

        $headers =
            @{
                Authorization =
                    "Bearer $Token"

                Accept =
                    'application/json'

                'User-Agent' =
                    'ShinySlack-History'
            }


        $cursor =
            ''

        $pages =
            0

        $added =
            0


        do {

            $uri =
                'https://slack.com/api/conversations.history' +
                '?channel=' +
                [Uri]::EscapeDataString($ChannelId) +
                '&oldest=' +
                [Uri]::EscapeDataString(
                    $Oldest.ToString(
                        '0.000000',
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                ) +
                '&inclusive=false' +
                '&limit=200'


            if($cursor){

                $uri +=
                    '&cursor=' +
                    [Uri]::EscapeDataString(
                        $cursor
                    )
            }


            $response =
                Invoke-RestMethod `
                    -Uri $uri `
                    -Headers $headers `
                    -Method Get `
                    -TimeoutSec 20


            if(!$response.ok){

                throw (
                    "Slack history failed for #{0}: {1}" -f
                    $ChannelName,
                    $response.error
                )
            }


            $messages =
                @(
                    $response.messages |
                    Sort-Object {
                        [double]$_.ts
                    }
                )


            foreach($message in $messages){

                if(!$message.ts){
                    continue
                }


                # Ignore structural channel events.
                if(
                    $message.subtype -in @(
                        'channel_join',
                        'channel_leave',
                        'channel_archive',
                        'channel_unarchive',
                        'channel_name',
                        'channel_topic',
                        'channel_purpose'
                    )
                ){
                    continue
                }


                if(
                    Append-RecoveredEvent `
                        -TeamId $TeamId `
                        -ChannelId $ChannelId `
                        -ChannelName $ChannelName `
                        -SlackTs ([string]$message.ts) `
                        -Sound $Sound `
                        -Known $Known
                ){

                    $added++
                }
            }


            $cursor =
                [string]$response.response_metadata.next_cursor


            $pages++

            # Prototype safety cap:
            # max 1,000 returned objects/channel/run.
            if($pages -ge 5){
                break
            }

        } while($cursor)


        return $added
    }


    function Invoke-Backfill {

        if(!(Test-Path -LiteralPath $authPath)){

            Write-Status `
                -Connected $false

            return
        }


        if(!(Test-Path -LiteralPath $configPath)){

            Write-Status `
                -Connected $true `
                -ErrorMessage 'No channel-routes.json.'

            return
        }


        $auth =
            Get-Content `
                -LiteralPath $authPath `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json


        $token =
            Unprotect-Token `
                ([string]$auth.protectedToken)


        if(!$token){

            Write-Status `
                -Connected $false `
                -ErrorMessage 'Stored Slack token could not be decrypted.'

            return
        }


        $cfg =
            Get-Content `
                -LiteralPath $configPath `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json


        $state =
            if(Test-Path -LiteralPath $statePath){

                try {

                    Get-Content `
                        -LiteralPath $statePath `
                        -Raw `
                        -Encoding UTF8 |
                    ConvertFrom-Json
                }
                catch {
                    $null
                }
            }


        $nowEpoch =
            [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()


        $oldest =
            if(
                $state -and
                [double]$state.lastSyncEpoch -gt 0
            ){

                [double]$state.lastSyncEpoch
            }
            else {

                # First connection gets a 24-hour lookback.
                [double]($nowEpoch - 86400)
            }


        $known =
            Get-KnownKeys


        $recovered =
            0

        $errors =
            @()


        $deepLinks =
            if($cfg.deepLinks){
                $cfg.deepLinks
            }
            else {
                $null
            }


        if($deepLinks){

            foreach(
                $property in
                $deepLinks.PSObject.Properties
            ){

                $channelName =
                    [string]$property.Name


                $teamId =
                    [string]$property.Value.team


                $channelId =
                    [string]$property.Value.channel


                if(
                    !$teamId -or
                    !$channelId
                ){
                    continue
                }


                # One user token currently represents one workspace.
                if(
                    $auth.teamId -and
                    $teamId -ne [string]$auth.teamId
                ){

                    continue
                }


                $sound =
                    ''


                if($cfg.routes){

                    $routeSound =
                        Get-PropertyValue `
                            -Object $cfg.routes `
                            -Name $channelName


                    if($routeSound){

                        try {

                            $sound =
                                Split-Path `
                                    -Leaf `
                                    ([string]$routeSound)
                        }
                        catch {

                            $sound =
                                [string]$routeSound
                        }
                    }
                }


                try {

                    $recovered +=
                        Invoke-SlackHistory `
                            -Token $token `
                            -ChannelId $channelId `
                            -Oldest $oldest `
                            -TeamId $teamId `
                            -ChannelName $channelName `
                            -Sound $sound `
                            -Known $known
                }
                catch {

                    $errors +=
                        "#{0}: {1}" -f
                        $channelName,
                        $_.Exception.Message
                }
            }
        }


        # Only advance checkpoint if every linked channel succeeded.
        if($errors.Count -eq 0){

            [ordered]@{
                lastSyncEpoch =
                    [double]$nowEpoch

                lastSync =
                    (Get-Date).ToString('o')
            } |
            ConvertTo-Json |
            Set-Content `
                -LiteralPath $statePath `
                -Encoding UTF8


            $newSync =
                [double]$nowEpoch
        }
        else {

            $newSync =
                $oldest
        }


        Trim-Ledger


        Write-Status `
            -Connected $true `
            -TeamId ([string]$auth.teamId) `
            -TeamName ([string]$auth.teamName) `
            -UserName ([string]$auth.userName) `
            -Recovered $recovered `
            -ErrorMessage ($errors -join '; ') `
            -LastSyncEpoch $newSync


        Log (
            "BACKFILL recovered={0} errors={1}" -f
            $recovered,
            $errors.Count
        )
    }


    $lastAutomaticRun =
        [datetime]::MinValue


    do {

        try {

            if(
                $Once -or
                (
                    (
                        (Get-Date) -
                        $lastAutomaticRun
                    ).TotalMinutes -ge 5
                )
            ){

                Invoke-Backfill

                $lastAutomaticRun =
                    Get-Date
            }
        }
        catch {

            Log (
                'BACKFILL_ERROR ' +
                $_.Exception.Message
            )


            Write-Status `
                -Connected (Test-Path $authPath) `
                -ErrorMessage $_.Exception.Message
        }


        if($Once){
            break
        }


        Start-Sleep `
            -Seconds $IntervalSeconds

    } while($true)
}
finally {

    if($hasMutex){

        try {
            $mutex.ReleaseMutex()
        }
        catch {}
    }


    $mutex.Dispose()
}