$ErrorActionPreference='SilentlyContinue'

$root=Join-Path $env:LOCALAPPDATA 'ShinySlack'
$modePath=Join-Path $root 'sound-ownership.json'
$statusPath=Join-Path $root 'sound-safety-status.json'
$launcher=Join-Path $root 'Start-ChannelRouter.ps1'
$modeScript=Join-Path $root 'Set-SoundOwnership.ps1'

function Write-Status {
    param(
        [string]$State,
        [bool]$Healthy,
        [string]$Message
    )

    $tmp=$statusPath+'.tmp'

    [pscustomobject]@{
        state=$State
        routerHealthy=$Healthy
        message=$Message
        lastCheck=(Get-Date).ToString('o')
    } |
    ConvertTo-Json |
    Set-Content $tmp -Encoding UTF8

    Move-Item $tmp $statusPath -Force
}

function Get-Mode {
    if(!(Test-Path $modePath)){
        return $null
    }

    try{
        Get-Content $modePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    }catch{
        return $null
    }
}

function Test-Router {
    $pidPath=Join-Path $root 'channel-router.pid.json'
    $stdout=Join-Path $root 'channel-router.stdout.log'

    if(
        !(Test-Path $pidPath) -or
        !(Test-Path $stdout)
    ){
        return $false
    }

    try{
        $info=
            Get-Content $pidPath -Raw |
            ConvertFrom-Json

        Get-Process `
            -Id ([int]$info.pid) `
            -ErrorAction Stop |
        Out-Null

        $age=(
            (Get-Date).ToUniversalTime() -
            (Get-Item $stdout).LastWriteTimeUtc
        ).TotalSeconds

        return ($age -le 25)
    }catch{
        return $false
    }
}

function Restart-Router {
    if(!(Test-Path $launcher)){
        return $false
    }

    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    Start-Process `
        -FilePath $ps `
        -ArgumentList @(
            '-NoProfile',
            '-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass',
            '-File',$launcher
        ) `
        -WindowStyle Hidden |
    Out-Null

    $deadline=(Get-Date).AddSeconds(8)

    while((Get-Date) -lt $deadline){
        Start-Sleep -Milliseconds 500

        if(Test-Router){
            return $true
        }
    }

    return $false
}

function Fallback {
    if(!(Test-Path $modeScript)){
        throw 'Sound ownership fallback script is missing.'
    }

    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    & $ps `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $modeScript `
        -Mode NativeFallback `
        -Reason safety-guard

    if($LASTEXITCODE -ne 0){
        throw 'Automatic fallback failed.'
    }
}

$mutex =
    New-Object `
        System.Threading.Mutex `
        -ArgumentList $false,'Local\ShinySlackSoundSafetyGuardV2'

$locked=$false

try{
    try{
        $locked=$mutex.WaitOne(0,$false)
    }catch [System.Threading.AbandonedMutexException] {
        $locked=$true
    }

    if(!$locked){
        exit 0
    }

    $bad=0

    while($true){
        $mode=Get-Mode

        if(
            !$mode -or
            [string]$mode.mode -ne 'routerExclusive'
        ){
            $bad=0

            Write-Status `
                'standby' `
                (Test-Router) `
                'Slack/cache fallback is available.'

            Start-Sleep 5
            continue
        }

        if([bool]$mode.transition){
            $bad=0

            Write-Status `
                'transition' `
                (Test-Router) `
                'Sound ownership transition in progress.'

            Start-Sleep 5
            continue
        }

        if(Test-Router){
            $bad=0

            Write-Status `
                'armed' `
                $true `
                'Router healthy. Automatic fallback armed.'

            Start-Sleep 5
            continue
        }

        $bad++

        Write-Status `
            'warning' `
            $false `
            'Router heartbeat missing. Recovery pending.'

        if($bad -lt 2){
            Start-Sleep 5
            continue
        }

        if(Restart-Router){
            $bad=0

            Write-Status `
                'armed' `
                $true `
                'Router restarted automatically.'

            Start-Sleep 5
            continue
        }

        try{
            Write-Status `
                'fallback' `
                $false `
                'Router recovery failed. Restoring Slack/cache audio.'

            Fallback

            Write-Status `
                'restored' `
                $false `
                'Slack/cache audio restored automatically.'
        }catch{
            Write-Status `
                'critical' `
                $false `
                (
                    'AUTOMATIC FALLBACK FAILED: ' +
                    $_.Exception.Message
                )
        }

        $bad=0
        Start-Sleep 5
    }
}finally{
    if($locked){
        try{
            $mutex.ReleaseMutex()
        }catch{}
    }

    $mutex.Dispose()
}