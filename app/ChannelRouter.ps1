param(
    [int]$PollMilliseconds = 50,
    [int]$SettleMilliseconds = 100
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName PresentationCore

$script:Build = "TOAST-ROUTER-V17"

$script:Root = Join-Path $env:LOCALAPPDATA "ShinySlack"
$script:ConfigPath = Join-Path $script:Root "channel-routes.json"
$script:LogPath = Join-Path $script:Root "channel-router.log"
$script:WaveCacheDir = Join-Path $script:Root "wave-cache"
$script:SoundPlayers = @{}

New-Item -ItemType Directory -Path $script:WaveCacheDir -Force | Out-Null

$script:Routes = @{}
$script:DefaultSound = $null
$script:Enabled = $true
$script:Volume = 1.0
$script:ConfigStamp = $null
$script:Players = New-Object System.Collections.ArrayList

$desktop = [System.Windows.Automation.AutomationElement]::RootElement

$teamCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    "OpenTeam"
)

$channelCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    "OpenChannel"
)

$messageCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    "Message"
)

function Say {
    param(
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Text -ForegroundColor $Color
}

function Write-RouterLog {
    param([string]$Message)

    if(
        [string]::IsNullOrWhiteSpace(
            $Message
        )
    ){
        return
    }


    # Do not write high-frequency steady-state polling noise.
    # This could generate enormous logs while adding no useful
    # information to Activity or Persistent Alerts.
    if(
        $Message.StartsWith(
            'STACK_STABLE ',
            [StringComparison]::Ordinal
        )
    ){
        return
    }


    try {

        Add-Content `
            -LiteralPath $script:LogPath `
            -Value (
                "{0} {1}" -f
                (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"),
                $Message
            ) `
            -Encoding UTF8
    }
    catch {}
}

function Load-Config {

    $routes = @{}
    $defaultSound = $null
    $enabled = $true
    $volume = 1.0

    if(Test-Path $script:ConfigPath) {

        try {
            $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 |
                ConvertFrom-Json

            if($null -ne $cfg.enabled) {
                $enabled = [bool]$cfg.enabled
            }

            if($null -ne $cfg.volume) {
                $volume = [double]$cfg.volume
            }

            if($null -ne $cfg.defaultSound) {
                $defaultSound = [string]$cfg.defaultSound
            }

            if($null -ne $cfg.routes) {

                foreach($p in $cfg.routes.PSObject.Properties) {
                    $routes[[string]$p.Name] = [string]$p.Value
                }
            }
        }
        catch {
            Say "CONFIG ERROR: $($_.Exception.Message)" Red
            return
        }
    }

    if($volume -lt 0) { $volume = 0 }
    if($volume -gt 1) { $volume = 1 }

    $script:Routes = $routes
    $script:DefaultSound = $defaultSound
    $script:Enabled = $enabled
    $script:Volume = $volume

    if(Test-Path $script:ConfigPath) {
        $script:ConfigStamp =
            (Get-Item $script:ConfigPath).LastWriteTimeUtc
    }

    Say ("Config loaded: routes={0} default={1}" -f `
        $routes.Count,
        $(if($defaultSound){"YES"}else{"NO"})
    ) DarkGray
}

function Reload-ConfigIfChanged {

    if(!(Test-Path $script:ConfigPath)) {
        return
    }

    $stamp = (Get-Item $script:ConfigPath).LastWriteTimeUtc

    if(
        $null -eq $script:ConfigStamp -or
        $stamp -ne $script:ConfigStamp
    ) {
        Load-Config
        Prime-SoundCache
        Say "Configuration reloaded." Cyan
    }
}

function Cleanup-Players {

    for($i = $script:Players.Count - 1; $i -ge 0; $i--) {

        if((Get-Date) -ge $script:Players[$i].Expires) {

            try {
                $script:Players[$i].Player.Stop()
                $script:Players[$i].Player.Close()
            } catch {}

            $script:Players.RemoveAt($i)
        }
    }
}

function Get-LowLatencyPlayer {
    param([string]$Path)

    if(
        [string]::IsNullOrWhiteSpace(
            $Path
        )
    ){
        return $null
    }


    if(!(Test-Path -LiteralPath $Path)){
        return $null
    }


    $full =
        [IO.Path]::GetFullPath(
            $Path
        )


    $item =
        Get-Item `
            -LiteralPath $full


    # SHINY-PERCEPTUAL-VOLUME-V2
    #
    # UI volume remains 0.00 - 1.00, but playback uses
    # a squared gain curve:
    #
    # 100% -> 1.0000 gain
    #  75% -> 0.5625 gain
    #  50% -> 0.2500 gain
    #  25% -> 0.0625 gain
    #
    # This gives the slider a much more useful perceived
    # loudness range than linear amplitude.

    $uiVolume =
        [Math]::Max(
            0.0,
            [Math]::Min(
                1.0,
                [double]$script:Volume
            )
        )


    $effectiveGain =
        [Math]::Pow(
            $uiVolume,
            2
        )


    $volumeKey =
        $uiVolume.ToString(
            '0.00',
            [Globalization.CultureInfo]::InvariantCulture
        )


    $gainKey =
        $effectiveGain.ToString(
            '0.0000',
            [Globalization.CultureInfo]::InvariantCulture
        )


    $curveKey =
        'p2'


    # Curve version is part of the player key so an existing
    # player from the old linear-volume implementation cannot
    # be reused.
    $key =
        "{0}|{1}|{2}|{3}" -f `
        $full,
        $item.LastWriteTimeUtc.Ticks,
        $curveKey,
        $volumeKey


    if(
        $script:SoundPlayers.ContainsKey(
            $key
        )
    ){
        return $script:SoundPlayers[$key]
    }


    $hash =
        (
            Get-FileHash `
                -LiteralPath $full `
                -Algorithm SHA256
        ).Hash


    $volumeFileKey =
        $volumeKey.Replace(
            '.',
            '_'
        )


    $gainFileKey =
        $gainKey.Replace(
            '.',
            '_'
        )


    # New filename namespace prevents the old linear WAV cache
    # from being reused at the same displayed percentage.
    $wav =
        Join-Path `
            $script:WaveCacheDir `
            (
                "{0}-{1}-v{2}-g{3}.wav" -f
                $hash,
                $curveKey,
                $volumeFileKey,
                $gainFileKey
            )


    if(!(Test-Path -LiteralPath $wav)){

        $ff =
            Get-Command `
                ffmpeg.exe `
                -ErrorAction SilentlyContinue


        if(!$ff){

            $ff =
                Get-Command `
                    ffmpeg `
                    -ErrorAction SilentlyContinue
        }


        if(!$ff){
            throw "ffmpeg is required for low-latency audio."
        }


        & $ff.Source `
            -loglevel error `
            -y `
            -i $full `
            -vn `
            -ac 2 `
            -ar 44100 `
            -filter:a ("volume={0}" -f $gainKey) `
            -c:a pcm_s16le `
            $wav


        if(
            $LASTEXITCODE -ne 0 -or
            !(Test-Path -LiteralPath $wav)
        ){
            throw "Could not build WAV cache for $full"
        }
    }


    $player =
        New-Object `
            System.Media.SoundPlayer `
            -ArgumentList $wav


    # Decode before notification time.
    $player.Load()


    $script:SoundPlayers[$key] =
        $player


    return $player
}

function Prime-SoundCache {

    $paths = @()

    if($script:DefaultSound) {
        $paths += $script:DefaultSound
    }

    foreach($p in $script:Routes.Values) {
        if($p) {
            $paths += $p
        }
    }

    foreach($path in @($paths | Select-Object -Unique)) {

        try {
            [void](Get-LowLatencyPlayer -Path $path)

            Say (
                "PRELOADED -> {0}" -f `
                [IO.Path]::GetFileName($path)
            ) DarkGray
        }
        catch {
            Say (
                "PRELOAD ERROR: {0}" -f `
                $_.Exception.Message
            ) Red
        }
    }
}

function Play-Sound {
    param(
        [string]$Path,
        [string]$Reason,
        [switch]$SimulatedTest
    )

    $testSuffix = if($SimulatedTest){ ' test=slackbot' } else { '' }

    if(
        [string]::IsNullOrWhiteSpace(
            $Path
        )
    ){
        Say "NO SOUND PATH CONFIGURED" Red
        return
    }


    if(!(Test-Path -LiteralPath $Path)){

        Say "MISSING SOUND: $Path" Red

        Write-RouterLog `
            "MISSING $Reason path=$Path"

        return
    }


    $name =
        [IO.Path]::GetFileName(
            $Path
        )


    # Mute affects audio only.
    # The event still goes to Activity + Persistent Alerts.
    if(
        !$script:Enabled -or
        $script:Volume -le 0
    ){

        Write-RouterLog (
            "{0} sound={1} backend=MUTED{2}" -f
            $Reason,
            $name,
            $testSuffix
        )


        Say (
            "MUTED -> {0}" -f
            $name
        ) DarkGray

        return
    }


    try {

        $player =
            Get-LowLatencyPlayer `
                -Path $Path


        if($null -eq $player){
            throw "No audio player available."
        }


        $player.Play()


        $pct =
            [Math]::Round(
                $script:Volume * 100
            )


        Say (
            "PLAYING -> {0} [{1}%]" -f
            $name,
            $pct
        ) Green


        # KEEP THIS EVENT FORMAT STABLE.
        Write-RouterLog (
            "{0} sound={1} backend=WAV{2}" -f
            $Reason,
            $name,
            $testSuffix
        )
    }
    catch {

        Say (
            "PLAYBACK ERROR: {0}" -f
            $_.Exception.Message
        ) Red


        Write-RouterLog (
            "PLAYBACK_ERROR {0} {1}" -f
            $Reason,
            $_.Exception.Message
        )
    }
}
function Get-RuntimeKey {
    param($Element)

    try {
        $rid = ($Element.GetRuntimeId() -join ".")
        if($rid) {
            return $rid
        }
    } catch {}

    try {
        $r = $Element.Current.BoundingRectangle
        return "{0}|{1}|{2}|{3}|{4}" -f `
            $Element.Current.Name,
            [int]$r.X,
            [int]$r.Y,
            [int]$r.Width,
            [int]$r.Height
    } catch {}

    return [guid]::NewGuid().ToString()
}

# SHINY-PRIVACY-HASHED-MESSAGE-FINGERPRINT-V1
function Get-MessageFingerprintHash {
    param($Element)


    if(!$Element){
        return ''
    }


    $raw =
        $null

    $bytes =
        $null

    $hash =
        $null

    $sha =
        $null


    try {

        $raw =
            [string]$Element.Current.Name


        if(
            [string]::IsNullOrWhiteSpace(
                $raw
            )
        ){
            return ''
        }


        $bytes =
            [Text.Encoding]::UTF8.GetBytes(
                $raw
            )


        $sha =
            [Security.Cryptography.SHA256]::Create()


        $hash =
            $sha.ComputeHash(
                $bytes
            )


        return (
            [BitConverter]::ToString(
                $hash
            )
        ).Replace(
            '-',
            ''
        ).ToLowerInvariant()
    }
    catch {

        return ''
    }
    finally {

        # Raw accessibility text is used only long enough to hash it.
        # No message body is written to logs, config, Activity, or Git.
        $raw =
            $null


        if($bytes){
            [Array]::Clear(
                $bytes,
                0,
                $bytes.Length
            )
        }


        if($hash){
            [Array]::Clear(
                $hash,
                0,
                $hash.Length
            )
        }


        if($sha){
            $sha.Dispose()
        }
    }
}

# SHINY-V17-NOTIFICATION-SURFACE-V2

$script:RawViewWalker =
    [System.Windows.Automation.TreeWalker]::RawViewWalker

$script:SlackPidCache =
    @{}

$script:SlackPidCacheStamp =
    [datetime]::MinValue


if(
    -not (
        'ShinySlackWindowTitleV17' -as
        [type]
    )
){

    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ShinySlackWindowTitleV17
{
    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    private static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder text,
        int count
    );

    public static string Read(long handle)
    {
        if (handle == 0)
            return String.Empty;

        var buffer =
            new StringBuilder(1024);

        GetWindowText(
            new IntPtr(handle),
            buffer,
            buffer.Capacity
        );

        return buffer.ToString();
    }
}
"@
}


function Refresh-SlackPidCache {

    if(
        (
            (Get-Date) -
            $script:SlackPidCacheStamp
        ).TotalSeconds -lt 2
    ){
        return
    }


    $next =
        @{}


    try {

        foreach(
            $proc in
            @(
                Get-Process `
                    slack `
                    -ErrorAction SilentlyContinue
            )
        ){

            $next[[int]$proc.Id] =
                $true
        }
    }
    catch {}


    $script:SlackPidCache =
        $next


    $script:SlackPidCacheStamp =
        Get-Date
}


function Test-SlackProcessElement {
    param($Element)


    if(!$Element){
        return $false
    }


    try {

        $processId =
            [int]$Element.Current.ProcessId


        if($processId -le 0){
            return $false
        }


        Refresh-SlackPidCache


        return (
            $script:SlackPidCache.ContainsKey(
                $processId
            )
        )
    }
    catch {

        return $false
    }
}


function Test-SlackNotificationElement {
    param(
        $Element,
        $Rect
    )


    if(
        !$Element -or
        $null -eq $Rect -or
        $Rect.Width -le 0 -or
        $Rect.Height -le 0
    ){
        return $false
    }


    # V17 ownership rule:
    #
    # 1. The accessibility element must belong to slack.exe.
    # 2. Prefer a positive identification of Slack's dedicated
    #    notification helper surface when UIA exposes it.
    # 3. If Electron hides that helper title/handle, accept only
    #    the exact accessibility classes the proven V3 detector
    #    used for Slack built-in notification cards.
    #
    # This removes ALL screen-position assumptions while keeping
    # Windows Notification Center out of scope.

    if(
        !(
            Test-SlackProcessElement `
                -Element $Element
        )
    ){
        return $false
    }


    $elementClass =
        ''


    try {

        $elementClass =
            [string]$Element.Current.ClassName
    }
    catch {}


    $node =
        $Element


    for(
        $depth = 0;
        $depth -lt 24 -and $node;
        $depth++
    ){

        try {

            $name =
                [string]$node.Current.Name


            $className =
                [string]$node.Current.ClassName


            $automationId =
                [string]$node.Current.AutomationId


            $nativeHandle =
                [long]$node.Current.NativeWindowHandle


            $nativeTitle =
                if($nativeHandle -ne 0){
                    [ShinySlackWindowTitleV17]::Read(
                        $nativeHandle
                    )
                }
                else {
                    ''
                }


            if(
                $name -match
                    '(?i)(app://resources/)?notifications\.html' -or
                $nativeTitle -match
                    '(?i)(app://resources/)?notifications\.html' -or
                $automationId -match
                    '(?i)slack.*notification|notification.*slack' -or
                $className -match
                    '(?i)slack.*notification|notification.*slack'
            ){

                return $true
            }


            $parent =
                $script:RawViewWalker.GetParent(
                    $node
                )


            if(
                !$parent -or
                [object]::ReferenceEquals(
                    $parent,
                    $desktop
                )
            ){
                break
            }


            $node =
                $parent
        }
        catch {

            break
        }
    }


    # Electron does not consistently expose the notification helper
    # window title to UIAutomation. These three class names are the
    # structural fingerprint already proven by the original Router.
    #
    # Message is still filtered later by proximity to an accepted
    # OpenChannel, so ordinary message content cannot independently
    # create a notification event.

    return (
        $elementClass -in
        @(
            'OpenTeam',
            'OpenChannel',
            'Message'
        )
    )
}

function Get-ToastTeams {

    $result = @{}

    $elements = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $teamCondition
    )

    foreach($e in $elements) {

        try {
            $rect = $e.Current.BoundingRectangle

            if(!(Test-SlackNotificationElement -Element $e -Rect $rect)) {
                continue
            }

            $key = Get-RuntimeKey $e

            $result[$key] = [pscustomobject]@{
                Element = $e
                Name = [string]$e.Current.Name
                X = [double]$rect.X
                Y = [double]$rect.Y
                W = [double]$rect.Width
                H = [double]$rect.Height
            }
        }
        catch {}
    }

    return $result
}

function Get-ToastChannels {

    $result = @()

    $elements = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $channelCondition
    )

    foreach($e in $elements) {

        try {
            $rect = $e.Current.BoundingRectangle

            if(!(Test-SlackNotificationElement -Element $e -Rect $rect)) {
                continue
            }

            $name = [string]$e.Current.Name

            if([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $channel = $name.Trim()

            if($channel.StartsWith("#")) {
                $channel = $channel.Substring(1)
            }

            $result += [pscustomobject]@{
                Key = Get-RuntimeKey $e
                Channel = $channel
                X = [double]$rect.X
                Y = [double]$rect.Y
                W = [double]$rect.Width
                H = [double]$rect.Height
            }
        }
        catch {}
    }

    return @($result)
}

function Get-ToastMessages {
    param($Channels)

    $result = @()

    if(@($Channels).Count -eq 0) {
        return @()
    }

    $elements = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $messageCondition
    )

    foreach($e in $elements) {

        try {
            $rect = $e.Current.BoundingRectangle

            if(
                $rect.Width -le 0 -or
                $rect.Height -le 0
            ) {
                continue
            }

            if(
                !(
                    Test-SlackNotificationElement `
                        -Element $e `
                        -Rect $rect
                )
            ) {
                continue
            }
$nearChannel = $false

            foreach($c in @($Channels)) {

                $horizontal =
                    ($rect.X -le ($c.X + $c.W + 120)) -and
                    (($rect.X + $rect.Width) -ge ($c.X - 120))

                $dy = $rect.Y - $c.Y

                if(
                    $horizontal -and
                    $dy -ge -40 -and
                    $dy -le 520
                ) {
                    $nearChannel = $true
                    break
                }
            }

            if(!$nearChannel) {
                continue
            }

            $result += [pscustomobject]@{
                Key     = Get-RuntimeKey $e
                Element = $e
                X       = [double]$rect.X
                Y       = [double]$rect.Y
                W       = [double]$rect.Width
                H       = [double]$rect.Height
            }
        }
        catch {}
    }

    return @($result)
}


function Find-ChannelForMessage {
    param(
        $Message,
        $Channels
    )

    $best = $null
    $bestDistance = 999999

    foreach($c in @($Channels)) {

        $horizontal =
            ($Message.X -le ($c.X + $c.W + 120)) -and
            (($Message.X + $Message.W) -ge ($c.X - 120))

        if(!$horizontal) {
            continue
        }

        $dy = $Message.Y - $c.Y

        if(
            $dy -ge -40 -and
            $dy -le 520 -and
            $dy -lt $bestDistance
        ) {
            $best = $c.Channel
            $bestDistance = $dy
        }
    }

    return $best
}

function Find-ChannelForToast {
    param(
        $Team,
        $Channels
    )

    $best = $null
    $bestDistance = 999999

    foreach($c in $Channels) {

        $horizontalOverlap =
            ($c.X -le ($Team.X + $Team.W + 80)) -and
            (($c.X + $c.W) -ge ($Team.X - 80))

        if(!$horizontalOverlap) {
            continue
        }

        # Channel normally appears directly below workspace/team.
        $distance = [Math]::Abs(
            $c.Y - ($Team.Y + $Team.H)
        )

        if($distance -lt $bestDistance -and $distance -lt 140) {
            $best = $c.Channel
            $bestDistance = $distance
        }
    }

    return $best
}

# SHINY-TEST-SLACKBOT-ROUTER-V1
# A one-shot test is executed inside the existing router so it uses
# the live route selection, cached sound player, Activity and alert deck.
# No Slack API calls, no simulated Slack UIA elements, no settings writes.
$script:SlackbotTestRequest = Join-Path $script:Root 'test-slackbot.request'
function Invoke-SlackbotTestRequest {
    if(!(Test-Path -LiteralPath $script:SlackbotTestRequest)){ return }
    try {
        $request = [IO.File]::ReadAllText($script:SlackbotTestRequest).Trim()
        Remove-Item -LiteralPath $script:SlackbotTestRequest -Force -ErrorAction Stop
        $requestedAt = [datetime]::Parse($request).ToUniversalTime()
        $age = ([datetime]::UtcNow - $requestedAt).TotalSeconds
        if($age -lt -2 -or $age -gt 10){
            Write-RouterLog 'TEST_SLACKBOT_IGNORED stale-request'
            return
        }
        $channel = 'Slackbot'
        if($script:Routes.ContainsKey($channel)) {
            $sound = $script:Routes[$channel]
            $reason = 'ROUTED channel=#Slackbot'
        } else {
            $sound = $script:DefaultSound
            $reason = 'DEFAULT channel=#Slackbot'
        }
        Write-RouterLog 'TEST_SLACKBOT_REQUEST accepted'
        Play-Sound -Path $sound -Reason $reason -SimulatedTest
    } catch {
        Write-RouterLog ("TEST_SLACKBOT_ERROR " + $_.Exception.Message)
    }
}
Load-Config
Prime-SoundCache

Say ""
Say "ShinySlack Toast Router V17" Cyan
Say "==========================" DarkCyan
Say ""
Say "Slack built-in notification detection owns the event." Green
Say "Channel is optional routing metadata." Green
Say "No channel/mapping -> DEFAULT." Yellow
Say ""
Say "READY." Green
Say ""

Write-RouterLog "START build=$script:Build mode=channel-first scope=slack-built-in location=any-monitor"

# Channel elements own normal channel notifications.
# OpenTeam is only a fallback for notifications that expose no channel.
$activeChannels = @{}
$recentChannelFires = @{}

# OpenChannel owns the first instant sound.
#
# Stack augmenter tracks HOW MANY notification cards have already
# been sounded for each channel. Counts only move upward during
# one visible stack session, so Slack repainting/rebuilding cards
# cannot create ghost encores.
$stackAccounted = @{}
$stackLastSeen  = @{}

# One primary OpenChannel fire per visible Slack stack session.
# RuntimeId rebuilds/repaints cannot create ghost primary sounds.
$primaryChannelSessions = @{}

# GHOST-GUARD-V1
#
# Slack can briefly remove/recreate the same toast accessibility
# tree. Remember identifiers from notifications that actually fired.
#
# RuntimeId match = strong identity.
# Message fingerprint fallback targets the observed ~8 second
# repaint cycle without creating a broad channel cooldown.
$recentPrimarySignatures = @{}
$primarySignatureTtlSeconds = 12

# Remember where/when a channel toast fired so the slower
# OpenTeam fallback cannot replay the same notification later.
$recentPrimaryToasts = @()

$pendingTeams = @{}
$activeTeams = @{}
$recentFallbackFires = @{}

$channelDedupeMilliseconds = 300
$fallbackMilliseconds = 650

$lastBeat = Get-Date

while($true) {

    try {

        Reload-ConfigIfChanged
        Cleanup-Players
        Invoke-SlackbotTestRequest

        $now = Get-Date

        # ------------------------------------------------------------
        # PRIMARY PATH
        # OpenChannel on a Slack built-in notification surface fires immediately.
        # ------------------------------------------------------------

        $channels = @(Get-ToastChannels)
        $presentChannels = @{}

        foreach($c in $channels) {

            $elementKey = [string]$c.Key

            if([string]::IsNullOrWhiteSpace($elementKey)) {
                continue
            }

            $presentChannels[$elementKey] = $true

            if($activeChannels.ContainsKey($elementKey)) {
                continue
            }

            $activeChannels[$elementKey] = $true

            # Slack can rebuild the accessibility element with a new
            # RuntimeId while the same toast is still visible.
            # Suppress only extremely-close repeats for the same channel.
            $channelKey = [string]$c.Channel

            # Primary sound may fire exactly once for the lifetime
            # of this visible channel stack.
            #
            # Same-channel additions are handled by STACK_EXTRA,
            # not by another OpenChannel primary fire.
            # ------------------------------------------------
            # GHOST-GUARD-V1
            # ------------------------------------------------

            $candidateSignatures = @()


            # Real UI Automation RuntimeId.
            #
            # Get-RuntimeKey's geometry fallback contains "|";
            # do NOT treat that fallback as persistent identity.
            if(
                $elementKey -and
                $elementKey.IndexOf('|') -lt 0
            ) {

                $candidateSignatures +=
                    "runtime|$channelKey|$elementKey"
            }


            # Message fingerprint fallback.
            #
            # Privacy rule:
            # UI Automation may expose Slack's accessible message text.
            # ShinySlack reads each string only long enough to compute
            # SHA-256, then retains only the hash for short-lived dedupe.
            # Sender/body fields are not parsed, logged, or persisted.

            try {

                $candidateMessages =
                    @(
                        Get-ToastMessages `
                            -Channels @($c) |
                        Sort-Object Y
                    )


                $messageHashes =
                    @(
                        $candidateMessages |
                        ForEach-Object {

                            Get-MessageFingerprintHash `
                                -Element $_.Element
                        } |
                        Where-Object {
                            ![string]::IsNullOrWhiteSpace($_)
                        }
                    )


                if($messageHashes.Count -gt 0) {

                    $candidateSignatures +=
                        (
                            "message-sha256|$channelKey|" +
                            ($messageHashes -join '||')
                        )
                }
            }
            catch {}

            $ghostReplay = $false
            $ghostReason = ''
            $ghostAgeMs  = 0


            foreach(
                $signature in
                @($candidateSignatures)
            ) {

                if(
                    !$recentPrimarySignatures.ContainsKey(
                        $signature
                    )
                ) {
                    continue
                }


                $signatureAge =
                    (
                        (Get-Date) -
                        $recentPrimarySignatures[$signature]
                    ).TotalMilliseconds


                # Same RuntimeId within 12 sec is the same UI object
                # repainting/reappearing.
                if(
                    $signature.StartsWith('runtime|') -and
                    $signatureAge -ge 0 -and
                    $signatureAge -le 12000
                ) {

                    $ghostReplay = $true
                    $ghostReason = 'runtime'
                    $ghostAgeMs  = [int]$signatureAge

                    break
                }


                # When Slack rebuilds RuntimeId, use the exact message
                # fingerprint only inside the repeatedly observed
                # repaint window (~8 sec).
                if(
                    $signature.StartsWith('message-sha256|') -and
                    $signatureAge -ge 6000 -and
                    $signatureAge -le 11500
                ) {

                    $ghostReplay = $true
                    $ghostReason = 'message-cycle'
                    $ghostAgeMs  = [int]$signatureAge

                    break
                }
            }


            if($ghostReplay) {

                Write-RouterLog (
                    "PRIMARY_SUPPRESSED ghost-{0} channel=#{1} ageMs={2}" -f `
                    $ghostReason,
                    $channelKey,
                    $ghostAgeMs
                )

                continue
            }

            if($primaryChannelSessions.ContainsKey($channelKey)) {

                Write-RouterLog `
                    "PRIMARY_SUPPRESSED session-active channel=#$channelKey"

                continue
            }

            $primaryChannelSessions[$channelKey] = Get-Date

            $signatureStamp = Get-Date

            foreach(
                $signature in
                @($candidateSignatures)
            ) {

                if(
                    ![string]::IsNullOrWhiteSpace(
                        $signature
                    )
                ) {

                    $recentPrimarySignatures[$signature] =
                        $signatureStamp
                }
            }

            $recentPrimaryToasts += [pscustomobject]@{
                Time = $now
                X = [double]$c.X
                Y = [double]$c.Y
                W = [double]$c.W
                H = [double]$c.H
                Channel = $channelKey
            }

            Say "----------------------------------------" DarkCyan
            Say "SLACK CHANNEL TOAST" Cyan
            Say "Channel:   #$channelKey" White

            if($script:Routes.ContainsKey($channelKey)) {

                Say "ROUTE MATCH" Green

                Play-Sound `
                    -Path $script:Routes[$channelKey] `
                    -Reason "ROUTED channel=#$channelKey"
            }
            else {

                Say "DEFAULT ROUTE" Yellow

                Play-Sound `
                    -Path $script:DefaultSound `
                    -Reason "DEFAULT channel=#$channelKey"
            }

            # Primary sound accounts for notification #1.
            # Any additional visible Message cards for this channel
            # will be handled by the stack augmenter below.
            $stackAccounted[$channelKey] = 1
            $stackLastSeen[$channelKey]  = Get-Date
        }

        # Allow a new toast to use the same RuntimeId after the old one disappears.
        foreach($key in @($activeChannels.Keys)) {

            if(!$presentChannels.ContainsKey($key)) {
                $activeChannels.Remove($key)
            }
        }

        # ------------------------------------------------------------
        # STACK AUGMENTER — COUNT LEDGER
        #
        # OpenChannel still owns notification #1 immediately.
        #
        # We count visible Slack Message cards by channel and only
        # play when that count EXCEEDS what has already been sounded.
        #
        # IMPORTANT:
        # The accounted count never decreases during a stack session.
        # Slack may repaint, rebuild, move or remove cards without
        # creating a fake new notification.
        # ------------------------------------------------------------

        $messages = @(Get-ToastMessages -Channels $channels)

        $visibleStackCounts = @{}

        foreach($m in $messages) {

            $channelForMessage =
                Find-ChannelForMessage `
                    -Message $m `
                    -Channels $channels

            if([string]::IsNullOrWhiteSpace($channelForMessage)) {
                continue
            }

            if(!$visibleStackCounts.ContainsKey($channelForMessage)) {
                $visibleStackCounts[$channelForMessage] = 0
            }

            $visibleStackCounts[$channelForMessage]++
        }


        foreach($stackChannel in @($visibleStackCounts.Keys)) {

            # Only augment a stack that was first claimed by the
            # proven OpenChannel primary trigger.
            if(!$stackAccounted.ContainsKey($stackChannel)) {
                continue
            }

            $visible =
                [int]$visibleStackCounts[$stackChannel]

            $accounted =
                [int]$stackAccounted[$stackChannel]

            $stackLastSeen[$stackChannel] = Get-Date


            if($visible -le $accounted) {

                Write-RouterLog (
                    "STACK_STABLE channel=#{0} visible={1} accounted={2}" -f `
                    $stackChannel,
                    $visible,
                    $accounted
                )

                continue
            }


            $extras = $visible - $accounted

            Write-RouterLog (
                "STACK_GROW channel=#{0} visible={1} accounted={2} extras={3}" -f `
                $stackChannel,
                $visible,
                $accounted,
                $extras
            )


            if($script:Routes.ContainsKey($stackChannel)) {

                $stackSound =
                    $script:Routes[$stackChannel]

                $stackReason =
                    "STACK_EXTRA channel=#$stackChannel"
            }
            else {

                $stackSound =
                    $script:DefaultSound

                $stackReason =
                    "STACK_EXTRA_DEFAULT channel=#$stackChannel"
            }


            for($extra = 0; $extra -lt $extras; $extra++) {

                # Preserve immediate primary playback while making
                # subsequent alerts individually audible.
                Start-Sleep -Milliseconds 180

                Play-Sound `
                    -Path $stackSound `
                    -Reason $stackReason
            }


            # Monotonic: never reduce this number while this stack
            # session remains alive.
            $stackAccounted[$stackChannel] = $visible
        }


        # ------------------------------------------------------------
        # EXPIRE FINISHED STACK SESSIONS
        #
        # Only reset after the channel header has actually disappeared
        # long enough to represent a new notification session.
        # ------------------------------------------------------------

        $visibleChannelNames = @{}

        foreach($c in $channels) {

            if($c.Channel) {
                $visibleChannelNames[[string]$c.Channel] = $true
            }
        }


        foreach($stackChannel in @($stackAccounted.Keys)) {

            if($visibleChannelNames.ContainsKey($stackChannel)) {
                continue
            }

            $lastSeen = $stackLastSeen[$stackChannel]

            if(
                !$lastSeen -or
                (((Get-Date) - $lastSeen).TotalMilliseconds -gt 1800)
            ) {
                Write-RouterLog `
                    "STACK_RESET channel=#$stackChannel"

                $stackAccounted.Remove($stackChannel)
                $stackLastSeen.Remove($stackChannel)

                if($primaryChannelSessions.ContainsKey($stackChannel)) {

                    $primaryChannelSessions.Remove($stackChannel)

                    Write-RouterLog `
                        "PRIMARY_SESSION_RESET channel=#$stackChannel"
                }
            }
        }

        # Expire ghost fingerprints quickly.
        foreach(
            $signature in
            @($recentPrimarySignatures.Keys)
        ) {

            if(
                (
                    $now -
                    $recentPrimarySignatures[$signature]
                ).TotalSeconds -gt
                $primarySignatureTtlSeconds
            ) {

                $recentPrimarySignatures.Remove(
                    $signature
                )
            }
        }

        # Keep recent-fire memory tiny.
        foreach($key in @($recentChannelFires.Keys)) {

            if(
                (($now - $recentChannelFires[$key]).TotalSeconds) -gt 3
            ) {
                $recentChannelFires.Remove($key)
            }
        }


        $recentPrimaryToasts = @(
            $recentPrimaryToasts |
            Where-Object {
                (($now - $_.Time).TotalSeconds) -le 3
            }
        )

        # ------------------------------------------------------------
        # FALLBACK PATH
        # For DMs / unusual Slack notifications with OpenTeam but no
        # OpenChannel, wait briefly before using DEFAULT.
        # ------------------------------------------------------------

        $teams = Get-ToastTeams
        $presentTeams = @{}

        foreach($key in $teams.Keys) {

            $presentTeams[$key] = $true

            if(!$activeTeams.ContainsKey($key)) {

                $activeTeams[$key] = $true

                $pendingTeams[$key] = [pscustomobject]@{
                    FirstSeen  = Get-Date
                    Team       = $teams[$key]
                    HadChannel = $false
                }
            }
        }

        # Remember whether each notification shell ever exposed a channel.
        # Slack sometimes removes OpenChannel before the fallback timer fires.
        foreach($key in @($pendingTeams.Keys)) {

            if(
                $presentTeams.ContainsKey($key) -and
                !$pendingTeams[$key].HadChannel
            ) {
                $seenChannel = Find-ChannelForToast `
                    -Team $teams[$key] `
                    -Channels $channels

                if($seenChannel) {
                    $pendingTeams[$key].HadChannel = $true
                }
            }
        }

        foreach($key in @($pendingTeams.Keys)) {

            if(!$presentTeams.ContainsKey($key)) {
                $pendingTeams.Remove($key)
                continue
            }

            $age = (
                (Get-Date) -
                $pendingTeams[$key].FirstSeen
            ).TotalMilliseconds

            if($age -lt $fallbackMilliseconds) {
                continue
            }

            $team = $teams[$key]

            # Once this shell exposed a channel, the fast path owns it
            # permanently. It may never become a delayed DEFAULT encore.
            if($pendingTeams[$key].HadChannel) {

                Write-RouterLog `
                    "FALLBACK_SUPPRESSED had-channel"

                $pendingTeams.Remove($key)
                continue
            }

            # If a channel is exposed, the primary channel path owns
            # this notification. Never play a second/default sound here.
            $channel = Find-ChannelForToast `
                -Team $team `
                -Channels $channels

            if($channel) {
                $pendingTeams.Remove($key)
                continue
            }

            # OpenChannel may disappear before this fallback timer
            # expires. Match this OpenTeam against a channel toast that
            # already fired at the same place/time.
            $ownedByPrimary = $false
            $teamFirstSeen = $pendingTeams[$key].FirstSeen

            foreach($p in $recentPrimaryToasts) {

                $timeDistance = [Math]::Abs(
                    ($p.Time - $teamFirstSeen).TotalMilliseconds
                )

                $horizontalOverlap =
                    ($p.X -le ($team.X + $team.W + 80)) -and
                    (($p.X + $p.W) -ge ($team.X - 80))

                $verticalDistance = [Math]::Abs(
                    $p.Y - ($team.Y + $team.H)
                )

                if(
                    $timeDistance -lt 500 -and
                    $horizontalOverlap -and
                    $verticalDistance -lt 160
                ) {
                    $ownedByPrimary = $true
                    break
                }
            }

            if($ownedByPrimary) {
                Write-RouterLog "FALLBACK_SUPPRESSED primary-owned"
                $pendingTeams.Remove($key)
                continue
            }

            $fallbackKey = [string]$team.Name
            $lastFallback = $recentFallbackFires[$fallbackKey]

            if(
                $lastFallback -and
                (((Get-Date) - $lastFallback).TotalMilliseconds -lt 600)
            ) {
                $pendingTeams.Remove($key)
                continue
            }

            $recentFallbackFires[$fallbackKey] = Get-Date

            Say "----------------------------------------" DarkCyan
            Say "SLACK TOAST DETECTED" Cyan

            if($team.Name) {
                Say "Workspace: $($team.Name)" DarkGray
            }

            Say "Channel:   [none exposed]" Yellow
            Say "DEFAULT ROUTE" Yellow

            Play-Sound `
                -Path $script:DefaultSound `
                -Reason "DEFAULT channel=unknown"

            $pendingTeams.Remove($key)
        }

        foreach($key in @($activeTeams.Keys)) {

            if(!$presentTeams.ContainsKey($key)) {
                $activeTeams.Remove($key)
                $pendingTeams.Remove($key)
            }
        }


        if(((Get-Date) - $lastBeat).TotalSeconds -ge 10) {

            Say (
                "[alive] routes={0} channels={1} teams={2}" -f `
                $script:Routes.Count,
                $activeChannels.Count,
                $activeTeams.Count
            ) DarkGray

            $lastBeat = Get-Date
        }
    }
    catch {

        Say "ROUTER ERROR: $($_.Exception.Message)" Red
        Write-RouterLog "ERROR $($_.Exception.Message)"

        Start-Sleep -Milliseconds 250
    }

    Start-Sleep -Milliseconds $PollMilliseconds
}
