param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('RouterExclusive','NativeFallback')]
    [string]$Mode,
    [string]$Reason='dashboard'
)

$ErrorActionPreference='Stop'

$root=Join-Path $env:LOCALAPPDATA 'ShinySlack'
$configPath=Join-Path $root 'channel-routes.json'
$modePath=Join-Path $root 'sound-ownership.json'
$rollbackMeta=Join-Path $root 'sound-ownership-rollback.json'
$rollbackBytes=Join-Path $root 'sound-ownership-rollback.bin'
$statePath=Join-Path $root 'state.json'
$common=Join-Path $root 'ShinySlack.Common.ps1'
$launcher=Join-Path $root 'Start-ChannelRouter.ps1'
$watcher=Join-Path $root 'Watch-ShinySlack.ps1'

if(!(Test-Path $common)){ throw 'ShinySlack.Common.ps1 is missing.' }
. $common

function Write-JsonAtomic {
    param([string]$Path,$Object)

    $tmp=$Path+'.tmp'
    [IO.File]::WriteAllText(
        $tmp,
        ($Object|ConvertTo-Json -Depth 10),
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item $tmp $Path -Force
}

function Read-RouterConfig {
    if(!(Test-Path $configPath)){ throw 'channel-routes.json is missing.' }
    Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-RouterConfig {
    param($Config)
    Write-JsonAtomic $configPath $Config
}

function Set-RouterEnabled {
    param([bool]$Enabled)

    $cfg=Read-RouterConfig

    if($cfg.PSObject.Properties['enabled']){
        $cfg.enabled=$Enabled
    }else{
        $cfg|Add-Member -NotePropertyName enabled -NotePropertyValue $Enabled
    }

    Save-RouterConfig $cfg
}

function Test-RouterHealthy {
    $pidPath=Join-Path $root 'channel-router.pid.json'
    $stdout=Join-Path $root 'channel-router.stdout.log'

    if(!(Test-Path $pidPath) -or !(Test-Path $stdout)){ return $false }

    try{
        $info=Get-Content $pidPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $proc=Get-Process -Id ([int]$info.pid) -ErrorAction Stop

        if($proc.ProcessName -ne 'powershell'){ return $false }

        $age=(
            (Get-Date).ToUniversalTime() -
            (Get-Item $stdout).LastWriteTimeUtc
        ).TotalSeconds

        return ($age -le 25)
    }catch{
        return $false
    }
}

function Ensure-RouterHealthy {
    if(Test-RouterHealthy){ return }

    if(!(Test-Path $launcher)){
        throw 'Start-ChannelRouter.ps1 is missing.'
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

    $deadline=(Get-Date).AddSeconds(10)

    while((Get-Date) -lt $deadline){
        Start-Sleep -Milliseconds 500
        if(Test-RouterHealthy){ return }
    }

    throw 'Router did not become healthy. Slack audio was not suppressed.'
}

function Test-RouterAudioReady {
    $cfg=Read-RouterConfig

    if(!$cfg.defaultSound){
        throw 'Choose a Router Default sound first.'
    }

    if(!(Test-Path ([string]$cfg.defaultSound))){
        throw 'Router Default sound file is missing.'
    }

    $volume=if($null -ne $cfg.volume){ [double]$cfg.volume }else{ 1.0 }

    if($volume -le 0){
        throw 'Router volume is 0%. Raise it before enabling Router mode.'
    }
}

function Get-WatcherStartup {
    Join-Path `
        ([Environment]::GetFolderPath('Startup')) `
        'ShinySlack-Watcher.cmd'
}

function Stop-LegacyWatcher {
    try{
        Get-CimInstance `
            Win32_Process `
            -Filter "Name='powershell.exe'" `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'Watch-ShinySlack\.ps1'
        } |
        ForEach-Object {
            Stop-Process `
                -Id $_.ProcessId `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }catch{}

    $cmd=Get-WatcherStartup
    $disabled=$cmd+'.router-disabled'

    if(Test-Path $cmd){
        Move-Item $cmd $disabled -Force
    }
}

function Start-LegacyWatcher {
    $cmd=Get-WatcherStartup
    $disabled=$cmd+'.router-disabled'

    if(!(Test-Path $cmd) -and (Test-Path $disabled)){
        Move-Item $disabled $cmd -Force
    }

    if(Test-Path $watcher){
        $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        Start-Process `
            -FilePath $ps `
            -ArgumentList @(
                '-NoProfile',
                '-WindowStyle','Hidden',
                '-ExecutionPolicy','Bypass',
                '-File',$watcher
            ) `
            -WindowStyle Hidden |
        Out-Null
    }
}

function Save-Mode {
    param(
        [string]$Name,
        [bool]$Transition,
        [bool]$Suppressed,
        [string]$Error=''
    )

    Write-JsonAtomic `
        $modePath `
        ([ordered]@{
            version=1
            mode=$Name
            transition=$Transition
            nativeSuppressed=$Suppressed
            lastChange=(Get-Date).ToString('o')
            lastReason=$Reason
            lastError=$Error
        })
}

function Write-Region {
    param(
        [string]$File,
        [long]$Offset,
        [byte[]]$Bytes,
        [int]$TimeoutSeconds = 12
    )

    $deadline =
        (Get-Date).AddSeconds(
            [Math]::Max(
                2,
                $TimeoutSeconds
            )
        )

    $lastError =
        $null


    while((Get-Date) -lt $deadline){

        $stream =
            $null

        try{

            $stream =
                [IO.File]::Open(
                    $File,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None
                )


            if(
                ($Offset + $Bytes.Length) -gt
                $stream.Length
            ){

                throw (
                    'Saved cache region is outside the current file.'
                )
            }


            $stream.Position =
                $Offset


            $stream.Write(
                $Bytes,
                0,
                $Bytes.Length
            )


            $stream.Flush()


            return
        }
        catch [System.IO.IOException] {

            $lastError =
                $_.Exception


            Start-Sleep `
                -Milliseconds 250
        }
        finally {

            if($stream){

                try{
                    $stream.Dispose()
                }
                catch{}
            }
        }
    }


    $detail =
        if($lastError){
            $lastError.Message
        }
        else {
            'unknown lock'
        }


    throw (
        'Slack cache file remained locked for ' +
        $TimeoutSeconds +
        ' seconds after Slack shutdown. ' +
        'No cache write was completed. Last error: ' +
        $detail
    )
}

function Capture-And-Silence {
    if(!(Test-Path $statePath)){
        throw 'Legacy sound state is missing. Repair the current sound first.'
    }

    $state=
        Get-Content `
            $statePath `
            -Raw `
            -Encoding UTF8 |
        ConvertFrom-Json

    $file=[string]$state.File
    $offset=[long]$state.Offset
    $slot=[int]$state.SlotLength

    if(
        !$file -or
        !(Test-Path $file) -or
        $slot -lt 1000
    ){
        throw 'Saved Slack sound cache region is unavailable.'
    }

    $current=
        Read-RegionBytes `
            -File $file `
            -Offset $offset `
            -Length $slot

    if(!$current){
        throw 'Could not read the current Slack sound cache region.'
    }

    [IO.File]::WriteAllBytes(
        $rollbackBytes,
        [byte[]]$current
    )

    Write-JsonAtomic `
        $rollbackMeta `
        ([ordered]@{
            file=$file
            offset=$offset
            length=$slot
            hash=(Get-Sha256Hex $current)
            saved=(Get-Date).ToString('o')
        })

    $silent=Join-Path $root 'silent-slack.mp3'

    if(!(Test-Path $silent)){
        throw 'silent-slack.mp3 is missing.'
    }

    $silentBytes=[IO.File]::ReadAllBytes($silent)

    if($silentBytes.Length -gt $slot){
        throw 'Silent sound is larger than the cache slot.'
    }

    $padded=
        New-PaddedCustomBytes `
            -CustomBytes $silentBytes `
            -SlotLength $slot

    $wasRunning=
        [bool](
            Get-Process `
                slack `
                -ErrorAction SilentlyContinue
        )

    $exe=Get-SlackExePath

    if($wasRunning){
        Stop-SlackForPatch | Out-Null
        Start-Sleep -Milliseconds 1200
    }

    try{
        Write-Region `
            -File $file `
            -Offset $offset `
            -Bytes ([byte[]]$padded)

        $verify=
            Read-RegionBytes `
                -File $file `
                -Offset $offset `
                -Length $slot

        if(
            !$verify -or
            (Get-Sha256Hex $verify) -ne
            (Get-Sha256Hex $padded)
        ){
            throw 'Slack silence verification failed.'
        }
    }finally{
        if($wasRunning){
            Start-SlackAfterPatch -ExePath $exe
        }
    }
}

function Restore-ExactFallback {
    if(
        !(Test-Path $rollbackMeta) -or
        !(Test-Path $rollbackBytes)
    ){
        return $false
    }

    try{
        $meta=
            Get-Content `
                $rollbackMeta `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json

        $file=[string]$meta.file
        $offset=[long]$meta.offset
        $length=[int]$meta.length
        $bytes=[IO.File]::ReadAllBytes($rollbackBytes)

        if(
            !(Test-Path $file) -or
            $bytes.Length -ne $length
        ){
            return $false
        }

        $wasRunning=
            [bool](
                Get-Process `
                    slack `
                    -ErrorAction SilentlyContinue
            )

        $exe=Get-SlackExePath

        if($wasRunning){
            Stop-SlackForPatch | Out-Null
            Start-Sleep -Milliseconds 1200
        }

        try{
            Write-Region `
                -File $file `
                -Offset $offset `
                -Bytes ([byte[]]$bytes)

            $verify=
                Read-RegionBytes `
                    -File $file `
                    -Offset $offset `
                    -Length $length

            if(
                !$verify -or
                (Get-Sha256Hex $verify) -ne
                ([string]$meta.hash)
            ){
                return $false
            }
        }finally{
            if($wasRunning){
                Start-SlackAfterPatch -ExePath $exe
            }
        }

        return $true
    }catch{
        return $false
    }
}

$mutex =
    New-Object `
        System.Threading.Mutex `
        -ArgumentList $false,'Local\ShinySlackSoundOwnershipV2'

$locked=$false
$previous='legacy'
$previousRouterEnabled=$true

try{
    try{
        $locked=$mutex.WaitOne(0,$false)
    }catch [System.Threading.AbandonedMutexException] {
        $locked=$true
    }

    if(!$locked){
        throw 'Another sound ownership transition is already running.'
    }

    if(Test-Path $modePath){
        try{
            $previous=
                [string](
                    Get-Content $modePath -Raw |
                    ConvertFrom-Json
                ).mode
        }catch{}
    }

    try{
        $previousRouterEnabled =
            [bool](Read-RouterConfig).enabled
    }
    catch{
        $previousRouterEnabled =
            $true
    }


    Save-Mode $previous $true $false

    if($Mode -eq 'RouterExclusive'){
        Test-RouterAudioReady

        Set-RouterEnabled $true

        Ensure-RouterHealthy

        Stop-LegacyWatcher

        Capture-And-Silence

        Ensure-RouterHealthy

        Save-Mode 'routerExclusive' $false $true

        Write-Host 'ShinySlack Router now owns notification audio. Safety fallback is armed.'
    }else{
        $restored=Restore-ExactFallback

        Start-LegacyWatcher

        if(!$restored){
            $repair=Join-Path $root 'Repair-ShinySlack.ps1'

            if(Test-Path $repair){
                & $repair -RestartSlack

                if($LASTEXITCODE -ne 0){
                    throw 'Exact fallback was unavailable and legacy repair failed.'
                }
            }else{
                throw 'Exact fallback was unavailable and Repair-ShinySlack.ps1 is missing.'
            }
        }

        Set-RouterEnabled $false

        Save-Mode 'nativeFallback' $false $false

        Write-Host 'Slack/cache fallback restored. Router audio is disabled.'
    }
}catch{

    $failure =
        $_.Exception.Message


    if($Mode -eq 'RouterExclusive'){

        try{
            [void](
                Restore-ExactFallback
            )
        }
        catch{}
    }


    try{
        Set-RouterEnabled `
            -Enabled $previousRouterEnabled
    }
    catch{}


    Save-Mode `
        'legacy' `
        $false `
        $false `
        $failure


    try{
        Start-LegacyWatcher
    }
    catch{}


    throw $failure
}finally{
    if($locked){
        try{
            $mutex.ReleaseMutex()
        }catch{}
    }

    $mutex.Dispose()
}