param(
    [switch]$StagedOnly
)

$ErrorActionPreference = 'Stop'

$repo =
    Split-Path `
        -Parent `
        $PSScriptRoot

$root =
    Join-Path `
        $env:LOCALAPPDATA `
        'ShinySlack'

Set-Location $repo

$failures =
    New-Object System.Collections.Generic.List[string]

function Fail {
    param([string]$Message)

    [void]$failures.Add(
        $Message
    )
}

$web =
    Get-Content `
        (Join-Path $repo 'app\ShinySlack-Web.ps1') `
        -Raw `
        -Encoding UTF8

$router =
    Get-Content `
        (Join-Path $repo 'app\ChannelRouter.ps1') `
        -Raw `
        -Encoding UTF8

$history =
    Get-Content `
        (Join-Path $repo 'app\HistoryBackfill.ps1') `
        -Raw `
        -Encoding UTF8

if(
    $web -notmatch
    '\[Net\.IPAddress\]::Loopback'
){
    Fail 'Web server is not explicitly bound to loopback.'
}

if(
    $web -notmatch
    'RandomNumberGenerator'
){
    Fail 'Web API token is not generated with a cryptographic RNG.'
}

if(
    $web -match
    '1\.\.32\s*\|\s*ForEach-Object\s*\{\s*Get-Random'
){
    Fail 'Legacy Get-Random web token generation is still present.'
}

if(
    $web -notmatch
    '\$script:HistoryFeatureEnabled\s*=\s*\$false'
){
    Fail 'History API is not hard-disabled for v2.7.5.'
}

if(
    $history -notmatch
    'SHINY-PRIVACY-HISTORY-WORKER-DISABLED-275-V1'
){
    Fail 'History worker is not disabled for v2.7.5.'
}

if(
    $router -notmatch
    'Get-MessageFingerprintHash'
){
    Fail 'Router does not hash transient UIA message text.'
}

if(
    $router -match
    '\$messageParts'
){
    Fail 'Router still retains raw messageParts for dedupe.'
}

$blockedRuntimePattern =
    '(^|/)(channel-routes\.json|' +
    'history-auth\.json|' +
    'history-backfill-(state|status)\.json|' +
    'notification-ledger\.jsonl|' +
    'persistent-alerts(-window)?\.json|' +
    'sound-ownership(-rollback)?\.json|' +
    'sound-safety-status\.json|' +
    'channel-router\.pid\.json|' +
    'watcher(\.heartbeat)?\.json|' +
    'watcher\.pid|' +
    'web\.(pid|port|version)|' +
    'agent\.version|' +
    'custom\.mp3)$|' +
    '(^|/)(channel-sounds|wave-cache|backups|web-ops)/'

$tracked =
    @(
        git ls-files
    )

foreach($file in $tracked){

    $normalized =
        $file -replace '\\','/'

    if(
        $normalized -match
        $blockedRuntimePattern
    ){
        Fail (
            'Private runtime file is tracked by Git: ' +
            $normalized
        )
    }
}

$tokenPattern =
    'xox' +
    '[A-Za-z]-' +
    '[A-Za-z0-9-]{20,}'

if($StagedOnly){

    $staged =
        git diff `
            --cached `
            --no-color `
            --unified=0

    if(
        ($staged -join "`n") -match
        $tokenPattern
    ){
        Fail 'A Slack-style token pattern appears in staged content.'
    }
}
else {

    $tokenHit =
        & git grep `
            -I `
            -q `
            -E `
            $tokenPattern `
            -- `
            .

    if($LASTEXITCODE -eq 0){
        Fail 'A Slack-style token pattern exists in tracked repository content.'
    }
}

$configPath =
    Join-Path `
        $root `
        'channel-routes.json'


function Get-GitLiteralHitFiles {
    param(
        [string]$Literal
    )


    if(
        [string]::IsNullOrWhiteSpace(
            $Literal
        )
    ){
        return @()
    }


    $output =
        @(
            & git grep `
                -I `
                -F `
                -l `
                -- `
                $Literal `
                2>$null
        )


    return @(
        $output |
        Where-Object {
            $_
        } |
        Sort-Object -Unique
    )
}


function Test-TextContainsChannelLiteral {
    param(
        [string]$Text,
        [string]$Channel
    )


    if(
        [string]::IsNullOrWhiteSpace(
            $Text
        ) -or
        [string]::IsNullOrWhiteSpace(
            $Channel
        )
    ){
        return $false
    }


    $escaped =
        [regex]::Escape(
            $Channel
        )


    # Channel names can be ordinary English words. Treat them as
    # private-source leakage only when they appear in a Slack-like
    # literal context rather than coincidental prose.
    $pattern =
        '(?i)' +
        '(?:' +
            '\#' + $escaped + '(?![a-z0-9_-])' +
            '|' +
            '[''"]' + $escaped + '[''"]' +
            '|' +
            '`' + $escaped + '`' +
        ')'


    return (
        $Text -match
        $pattern
    )
}


function Get-ChannelLiteralHitFiles {
    param(
        [string]$Channel
    )


    $candidateFiles =
        New-Object System.Collections.Generic.HashSet[string]


    foreach(
        $literal in
        @(
            ('#' + $Channel),
            ("'" + $Channel + "'"),
            ('"' + $Channel + '"'),
            ('`' + $Channel + '`')
        )
    ){

        foreach(
            $file in
            @(
                Get-GitLiteralHitFiles `
                    -Literal $literal
            )
        ){

            [void]$candidateFiles.Add(
                $file
            )
        }
    }


    return @(
        $candidateFiles |
        Sort-Object
    )
}


if(Test-Path -LiteralPath $configPath){

    try {

        $cfg =
            Get-Content `
                -LiteralPath $configPath `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json


        $privateIds =
            New-Object System.Collections.Generic.HashSet[string]


        $privateChannelNames =
            New-Object System.Collections.Generic.HashSet[string]


        if($cfg.routes){

            foreach(
                $p in
                $cfg.routes.PSObject.Properties
            ){

                $value =
                    ([string]$p.Name).Trim()


                if(
                    $value -and
                    $value -notmatch
                    '(?i)^slackbot$'
                ){
                    [void]$privateChannelNames.Add(
                        $value
                    )
                }
            }
        }


        if($cfg.deepLinks){

            foreach(
                $p in
                $cfg.deepLinks.PSObject.Properties
            ){

                $name =
                    ([string]$p.Name).Trim()


                if(
                    $name -and
                    $name -notmatch
                    '(?i)^slackbot$'
                ){
                    [void]$privateChannelNames.Add(
                        $name
                    )
                }


                foreach(
                    $candidate in
                    @(
                        [string]$p.Value.team,
                        [string]$p.Value.channel
                    )
                ){

                    $value =
                        $candidate.Trim()


                    if($value){
                        [void]$privateIds.Add(
                            $value
                        )
                    }
                }
            }
        }


        # SHINY-PRIVACY-HISTORY-ID-AUDIT-V1
        if(!$StagedOnly){

            foreach($value in $privateIds){

                $historyHit =
                    @(
                        git log `
                            --branches `
                            --tags `
                            "-S$value" `
                            --format="%H" `
                            -1
                    )

                if($historyHit.Count -gt 0){

                    Fail (
                        'A local Slack team/channel ID exists in reachable branch/tag Git history.'
                    )
                }
            }
        }

        # Team/channel IDs are high-entropy identifiers. Any exact
        # occurrence in tracked Git content is treated as leakage.
        foreach($value in $privateIds){

            $hitFiles =
                @(
                    Get-GitLiteralHitFiles `
                        -Literal $value
                )


            if($hitFiles.Count -gt 0){

                Fail (
                    'A local Slack team/channel ID appears in tracked Git content. Files: ' +
                    ($hitFiles -join ', ')
                )
            }
        }


        # Channel names can be common words. Require Slack-like
        # literal context so "general" in prose does not false-positive.
        foreach($channel in $privateChannelNames){

            $hitFiles =
                @(
                    Get-ChannelLiteralHitFiles `
                        -Channel $channel
                )


            if($hitFiles.Count -gt 0){

                Fail (
                    'A local Slack channel name appears as a Slack-like literal in tracked Git content. Files: ' +
                    ($hitFiles -join ', ')
                )
            }
        }


        if($StagedOnly){

            $stagedText =
                (
                    @(
                        git diff `
                            --cached `
                            --no-color `
                            --unified=0
                    ) -join "`n"
                )


            foreach($value in $privateIds){

                if(
                    $value -and
                    $stagedText.Contains(
                        $value
                    )
                ){

                    Fail (
                        'A local Slack team/channel ID appears in staged content.'
                    )
                }
            }


            foreach($channel in $privateChannelNames){

                if(
                    Test-TextContainsChannelLiteral `
                        -Text $stagedText `
                        -Channel $channel
                ){

                    Fail (
                        'A local Slack channel name appears as a Slack-like literal in staged content.'
                    )
                }
            }
        }
    }
    catch {

        Fail (
            'Could not audit local channel-routes.json: ' +
            $_.Exception.Message
        )
    }
}

if($failures.Count -gt 0){

    Write-Host ''
    Write-Host 'SHINYSLACK PRIVACY AUDIT: FAIL' -ForegroundColor Red

    foreach($failure in $failures){
        Write-Host (' - ' + $failure) -ForegroundColor Yellow
    }

    exit 1
}

Write-Host ''
Write-Host 'SHINYSLACK PRIVACY AUDIT: PASS' -ForegroundColor Green
Write-Host ' - Web server: loopback-only' -ForegroundColor Green
Write-Host ' - Web API token: cryptographic RNG' -ForegroundColor Green
Write-Host ' - History API/worker: disabled for v2.7.5' -ForegroundColor Green
Write-Host ' - Live message text: SHA-256 dedupe only, not persisted' -ForegroundColor Green
Write-Host ' - Runtime/private files: not tracked' -ForegroundColor Green
Write-Host ' - Slack token patterns: none detected in audited Git content' -ForegroundColor Green
Write-Host ' - Local channel/team identifiers: none detected in tracked Git content' -ForegroundColor Green

exit 0