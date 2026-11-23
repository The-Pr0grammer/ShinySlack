# SHINY-DECK-SPARKLE-279-V1: U+2728 header titles; keep four-dot drag grip.
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
$log  = Join-Path $root 'channel-router.log'
$settingsFile = Join-Path $root 'persistent-alerts.json'

$created = $false
$mutex = New-Object System.Threading.Mutex(
    $true,
    'Local\ShinySlackPersistentAlertsV6',
    [ref]$created
)

if(!$created){ exit }

$script:Alerts = New-Object System.Collections.ArrayList
$script:NextId = 1
$script:Tucked = $false
$script:TuckStarted = $null
$script:Carry = ''
$script:Offset = 0L
$script:AutoDismiss = $true
$script:AutoDismissSeconds = 15
$script:LastSettingsRead = [datetime]::MinValue
# SHINY-DECK-POLISH-STATE-V1
$script:DeckPositionFile =
    Join-Path `
        $root `
        'persistent-alerts-window.json'

$script:DeckPositionInitialized =
    $false

$script:DeckScrollOffset =
    0


# SHINY-DECK-FINISH-RESIZE-DIRECTION-V1
$script:DeckWidth = 460
$script:DeckHeight = 0  # zero = content-driven height
# SHINY-DECK-THREE-WAY-GROWTH-V1
# auto: grow with alerts; once: reset to one card, release on next arrival;
# locked: always show one card with overflow scrolling.
$script:DeckGrowthMode = 'auto'
$script:DeckGrowthArmedCount = 0
$script:ExpansionDirection = 'down'
$script:LastLayoutDirection = 'tucked'
$script:OverrideAnchorY = $null
$script:ActiveDeckScrollHandler =
    $null


$script:Palette = @(
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

# SHINY-ALERT-VISUAL-TOKENS-V1
$script:AlertVisual =
    [pscustomobject]@{
        PageBackground =
            [Drawing.Color]::FromArgb(
                9,
                11,
                17
            )

        CardBackground =
            [Drawing.Color]::FromArgb(
                8,
                11,
                17
            )

        HoverBackground =
            [Drawing.Color]::FromArgb(
                10,
                16,
                24
            )

        Border =
            [Drawing.Color]::FromArgb(
                37,
                44,
                58
            )

        HeaderSurface =
            [Drawing.Color]::FromArgb(
                14,
                18,
                27
            )

        ControlSurface =
            [Drawing.Color]::FromArgb(
                11,
                15,
                23
            )

        Text =
            [Drawing.Color]::FromArgb(
                245,
                247,
                251
            )

        SecondaryText =
            [Drawing.Color]::FromArgb(
                214,
                222,
                234
            )

        Muted =
            [Drawing.Color]::FromArgb(
                154,
                166,
                183
            )

        Meta =
            [Drawing.Color]::FromArgb(
                104,
                116,
                137
            )

        DefaultAccent =
            [Drawing.Color]::FromArgb(
                85,
                216,
                255
            )

        ScrollThumb =
            [Drawing.Color]::FromArgb(
                70,
                82,
                101
            )

        CardHeight =
            64

        CardRadius =
            13

        CardGap =
            9

        RailWidth =
            4
    }



# SHINY-2710-NATIVE-SAFE-THEMES-V1
# Palette surfaces only. No custom Paint event, brushes, or gradient constructors.
$script:NativeThemeName = ''
$script:NativeThemeLastCheck = [datetime]::MinValue
$script:NativeThemePath = Join-Path $root 'visual-theme.json'
function Sync-NativeTheme {
    if (((Get-Date) - $script:NativeThemeLastCheck).TotalMilliseconds -lt 1200) { return $false }
    $script:NativeThemeLastCheck = Get-Date
    $name = 'shiny'
    if (Test-Path -LiteralPath $script:NativeThemePath) {
        try {
            $cfg = Get-Content -LiteralPath $script:NativeThemePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@('shiny','ghost','retro','arcade') -contains [string]$cfg.theme) {
                $name = [string]$cfg.theme
            }
        } catch {
            # A partial/corrupted settings write must never interrupt alert handling.
            return $false
        }
    }
    if ($script:NativeThemeName -eq $name) { return $false }
    $script:NativeThemeName = $name
    $colors = switch ($name) {
        'ghost'  { @('#251b37','#161122','#21182f','#584570','#2b2040','#1e172e','#f4ecff','#e3d9f3','#bbaed1','#9986b0','#bd90ff','#77618c') }
        'retro'  { @('#c7d6ac','#d9e4c4','#d0dcb8','#587158','#b6c99a','#d9e4c4','#233727','#2e4732','#445b42','#526b50','#345b40','#748c65') }
        'arcade' { @('#182657','#0a1230','#101839','#4e5da4','#15214b','#0e1639','#f4f7ff','#dde6ff','#bbc4e7','#8e9ed0','#54dcff','#697cc1') }
        default  { @('#090b11','#080b11','#0a1018','#252c3a','#0e121b','#0b0f17','#f5f7fb','#d6deea','#9aa6b7','#687489','#55d8ff','#465265') }
    }
    $names = @('PageBackground','CardBackground','HoverBackground','Border','HeaderSurface','ControlSurface','Text','SecondaryText','Muted','Meta','DefaultAccent','ScrollThumb')
    for ($i=0; $i -lt $names.Count; $i++) {
        $script:AlertVisual.($names[$i]) = [Drawing.ColorTranslator]::FromHtml($colors[$i])
    }
    # Original deck form is instantiated once, so refresh its underlying canvas as well.
    if ($null -ne $form -and -not $form.IsDisposed) {
        $form.BackColor = $script:AlertVisual.PageBackground
        $form.ForeColor = $script:AlertVisual.Text
    }
    return $true
}
if(Test-Path $log) {
    try {
        $script:Offset = (Get-Item $log).Length
    } catch {}
}

if(!(Test-Path $settingsFile)) {
    [pscustomobject]@{
        autoDismiss = $true
        autoDismissSeconds = 15
    } |
    ConvertTo-Json -Compress |
    Set-Content $settingsFile -Encoding UTF8
}

function Read-Settings {
    if(((Get-Date) - $script:LastSettingsRead).TotalMilliseconds -lt 1500){
        return
    }

    $script:LastSettingsRead = Get-Date

    try {
        $s = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json

        if($null -ne $s.autoDismiss){
            $script:AutoDismiss = [bool]$s.autoDismiss
        }

        if($s.autoDismissSeconds){
            $script:AutoDismissSeconds =
                [Math]::Max(1,[int]$s.autoDismissSeconds)
        }
    } catch {}
}

# SHINY-EVENT-ACCENT-SEQUENCE-V1
$script:LastAccentIndex =
    -1


function Get-BaseAccentIndex {
    param(
        [string]$Key
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


    return [int](
        $hash %
        $script:Palette.Count
    )
}


function Get-NextAccentIndex {
    param(
        [string]$Key,
        [int]$PreviousIndex = -1
    )


    $index =
        Get-BaseAccentIndex `
            -Key $Key


    if(
        $script:Palette.Count -gt 1 -and
        $index -eq $PreviousIndex
    ){

        $index =
            (
                $index +
                1
            ) %
            $script:Palette.Count
    }


    return [int]$index
}


function Get-AccentColor {
    param(
        [int]$Index
    )


    if(
        $Index -lt 0 -or
        $Index -ge $script:Palette.Count
    ){
        $Index =
            0
    }


    [Drawing.ColorTranslator]::FromHtml(
        $script:Palette[$Index]
    )
}


function Initialize-AccentSequence {

    $script:LastAccentIndex =
        -1


    if(
        !(
            Test-Path `
                -LiteralPath $log
        )
    ){
        return
    }


    try {

        foreach(
            $line in
            @(
                Get-Content `
                    -LiteralPath $log `
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


            $script:LastAccentIndex =
                Get-NextAccentIndex `
                    -Key $candidate `
                    -PreviousIndex $script:LastAccentIndex
        }
    }
    catch {

        $script:LastAccentIndex =
            -1
    }
}


Initialize-AccentSequence

function New-Button {
    param(
        [string]$Text,
        [int]$Width = 28
    )

    $b =
        New-Object System.Windows.Forms.Button

    $b.Text =
        $Text

    $b.Width =
        $Width

    $b.Height =
        26

    $b.FlatStyle =
        'Flat'

    $b.FlatAppearance.BorderSize =
        1

    $b.FlatAppearance.BorderColor =
        $script:AlertVisual.Border

    $b.BackColor =
        $script:AlertVisual.ControlSurface

    $b.ForeColor =
        $script:AlertVisual.SecondaryText

    $b.Font =
        New-Object Drawing.Font(
            'Segoe UI',
            8.25,
            [Drawing.FontStyle]::Bold
        )

    $b.Cursor =
        [System.Windows.Forms.Cursors]::Hand

    $b
}

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = $script:AlertVisual.PageBackground
$form.ForeColor = $script:AlertVisual.Text
$form.Width = 390
$form.Height = 100
$form.Opacity = 1.0
$form.AutoScroll = $false
$form.Add_Move({
    if($script:DeckVolumeWindow -and $script:DeckVolumeWindow.Visible){Position-DeckVolumeWindow}
})
# SHINY-DECK-GLOBAL-WHEEL-V1
$form.Add_MouseWheel({
    param($sender,$eventArgs)

    if($script:ActiveDeckScrollHandler){
        & $script:ActiveDeckScrollHandler $eventArgs.Delta
    }
})


# SHINY-DECK-HOVER-HELP-V1
$script:DeckHoverHelp = New-Object System.Windows.Forms.ToolTip
$script:DeckHoverHelp.AutoPopDelay = 10000
$script:DeckHoverHelp.InitialDelay = 450
$script:DeckHoverHelp.ReshowDelay = 150
$script:DeckHoverHelp.ShowAlways = $true
# SHINY-DECK-HOVER-RESET-V8
# A hidden/reopened deck rebuilds every header/card control. Give those new
# controls a new native ToolTip instance instead of retaining the old HWND state.
function Reset-DeckHoverHelp {
    try {
        if($script:DeckHoverHelp){
            $script:DeckHoverHelp.RemoveAll()
            $script:DeckHoverHelp.Dispose()
        }
    } catch {}
    $script:DeckHoverHelp = New-Object System.Windows.Forms.ToolTip
    $script:DeckHoverHelp.AutoPopDelay = 10000
    $script:DeckHoverHelp.InitialDelay = 350
    $script:DeckHoverHelp.ReshowDelay = 100
    $script:DeckHoverHelp.ShowAlways = $true
    $script:DeckHoverHelp.Active = $true
}
# SHINY-DECK-EXPLICIT-HOVER-V7
# Show help as soon as the cursor enters a control. Rebuilt WinForms controls
# each receive their own stable callback; the native tooltip remains a fallback.
# SHINY-DECK-POPUP-HOVER-V11
# A lightweight hover-only popup survives hide/reopen and control re-rendering.
# The help is visible immediately on MouseEnter and never requires a click.
$script:DeckHoverPopup = $null
function Hide-DeckHoverPopup {
    try {
        if($null -ne $script:DeckHoverPopup){
            $script:DeckHoverPopup.Hide()
            $script:DeckHoverPopup.Dispose()
            $script:DeckHoverPopup = $null
        }
    } catch { $script:DeckHoverPopup = $null }
}
function Show-DeckHoverPopup {
    param($Control)
    if(!$Control -or $Control.IsDisposed -or !$form.Visible){ return }
    $description = [string]$Control.AccessibleDescription
    if([string]::IsNullOrWhiteSpace($description)){ return }
    Hide-DeckHoverPopup
    try {
        $popup = New-Object System.Windows.Forms.ToolStripDropDown
        $popup.AutoClose = $false
        $popup.AutoSize = $true
        $popup.Padding = New-Object System.Windows.Forms.Padding(5)
        $popup.BackColor = [Drawing.Color]::FromArgb(19,25,38)
        $popup.ForeColor = [Drawing.Color]::White

        $label = New-Object System.Windows.Forms.Label
        $label.AutoSize = $false
        $label.Size = New-Object Drawing.Size(380,44)
        $label.BackColor = [Drawing.Color]::FromArgb(19,25,38)
        $label.ForeColor = [Drawing.Color]::White
        $label.Font = New-Object Drawing.Font('Segoe UI',9)
        $label.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $label.Text = $description

        $hostItem = New-Object System.Windows.Forms.ToolStripControlHost -ArgumentList @($label)
        $hostItem.Margin = New-Object System.Windows.Forms.Padding(0)
        $hostItem.Padding = New-Object System.Windows.Forms.Padding(0)
        [void]$popup.Items.Add($hostItem)
        $popup.PerformLayout()

        $size = $popup.GetPreferredSize([Drawing.Size]::Empty)
        $work = [Windows.Forms.Screen]::FromControl($Control).WorkingArea
        $x = [int][Math]::Max($work.Left+8,[Math]::Min($work.Right-$size.Width-8,[Windows.Forms.Cursor]::Position.X-[int]($size.Width/2)))
        $headerY = if($script:Tucked){$form.Top}else{ if($script:ExpansionDirection -eq 'up'){$form.Bottom-40}else{$form.Top} }
        $above = [int]($headerY - $size.Height - 8)
        $below = [int]($headerY + 44)
        $y = if($above -ge $work.Top+6){$above}else{$below}
        $y = [int][Math]::Max($work.Top+6,[Math]::Min($work.Bottom-$size.Height-6,$y))
        $script:DeckHoverPopup = $popup
        $popup.Show((New-Object Drawing.Point($x,$y)))
    } catch {
        # A presentation failure must never interrupt the notification engine.
        try {
            [IO.File]::AppendAllText((Join-Path $root 'deck-hover-help.log'), $_.Exception.Message + [Environment]::NewLine)
        } catch {}
        Hide-DeckHoverPopup
    }
}
function Set-DeckHoverDescriptor {
    param($Control,[string]$HelpText)
    if(!$Control){ return }
    $Control.AccessibleDescription = [string]$HelpText
    $Control.Add_MouseEnter({
        param($sender,$eventArgs)
        Show-DeckHoverPopup $sender
    })
    $Control.Add_MouseLeave({
        Hide-DeckHoverPopup
    })
    $Control.Add_MouseDown({
        Hide-DeckHoverPopup
    })
}
# SHINY-DECK-LIFECYCLE-V6
$script:DeckHiddenAt = $null
function Get-DeckWorkingArea {

    try {

        $center =
            New-Object Drawing.Point(
                (
                    $form.Left +
                    [Math]::Max(
                        1,
                        [int]($form.Width / 2)
                    )
                ),
                (
                    $form.Top +
                    [Math]::Max(
                        1,
                        [int]($form.Height / 2)
                    )
                )
            )


        return (
            [System.Windows.Forms.Screen]::FromPoint(
                $center
            )
        ).WorkingArea
    }
    catch {

        return (
            [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        )
    }
}


function Clamp-DeckPosition {

    $wa =
        Get-DeckWorkingArea


    $margin =
        8


    $maxLeft =
        [Math]::Max(
            ($wa.Left + $margin),
            ($wa.Right - $form.Width - $margin)
        )


    $maxTop =
        [Math]::Max(
            ($wa.Top + $margin),
            ($wa.Bottom - $form.Height - $margin)
        )


    $form.Left =
        [Math]::Min(
            $maxLeft,
            [Math]::Max(
                ($wa.Left + $margin),
                $form.Left
            )
        )


    $form.Top =
        [Math]::Min(
            $maxTop,
            [Math]::Max(
                ($wa.Top + $margin),
                $form.Top
            )
        )
}


function Save-DeckPosition {

    try {

        $state =
            [ordered]@{
                x =
                    [int]$form.Left

                y =
                    [int]$form.Top

                width = [int]$script:DeckWidth
                height = [int]$script:DeckHeight
                growthMode = [string]$script:DeckGrowthMode
                direction = [string]$script:ExpansionDirection
                savedAt =
                    (Get-Date).ToString('o')
            } |
            ConvertTo-Json


        [IO.File]::WriteAllText(
            $script:DeckPositionFile,
            $state,
            (New-Object Text.UTF8Encoding($false))
        )
    }
    catch {}
}


function Position-Form {

    if(!$script:DeckPositionInitialized){

        $loaded =
            $false


        if(
            Test-Path `
                -LiteralPath $script:DeckPositionFile
        ){
            try {

                $saved =
                    Get-Content `
                        -LiteralPath $script:DeckPositionFile `
                        -Raw `
                        -Encoding UTF8 |
                    ConvertFrom-Json


                if(
                    $null -ne $saved.x -and
                    $null -ne $saved.y
                ){
                    $form.Left =
                        [int]$saved.x

                    $form.Top =
                        [int]$saved.y


                    if($null -ne $saved.width){
                        $script:DeckWidth = [Math]::Min(850,[Math]::Max(460,[int]$saved.width))
                    }
                    if($null -ne $saved.height){
                        $h = [int]$saved.height
                        $script:DeckHeight = if($h -gt 0){[Math]::Min(700,[Math]::Max(110,$h))}else{0}
                    }
                    if([string]$saved.direction -in @('up','down')){
                        $script:ExpansionDirection = [string]$saved.direction
                    }
                    if([string]$saved.growthMode -in @('auto','once','locked')){
                        $script:DeckGrowthMode = [string]$saved.growthMode
                        if($script:DeckGrowthMode -eq 'once'){
                            $script:DeckGrowthArmedCount = [int]$script:NextId
                        }
                        if($script:DeckGrowthMode -eq 'auto'){
                            # A height saved by manual dragging is temporary.
                            # The next new alert releases it back to auto growth.
                            if($script:DeckHeight -gt 0){ $script:DeckGrowthArmedCount = [int]$script:NextId }
                        }
                    }
$loaded =
                        $true
                }
            }
            catch {}
        }


        if(!$loaded){

            $wa =
                [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea


            $form.Left =
                $wa.Left + 12


            $form.Top =
                $wa.Bottom -
                $form.Height -
                12
        }


        $script:DeckPositionInitialized =
            $true
    }


    Clamp-DeckPosition
}


if(-not ('ShinySlackDeckDragV1' -as [type])){

    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ShinySlackDeckDragV1
{
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(
        IntPtr hWnd,
        int msg,
        IntPtr wParam,
        IntPtr lParam
    );
}
"@
}


# SHINY-DECK-ICONS-CORNERS-DOUBLECLICK-V1
$script:DeckHeaderDragOrigin = $null
function Toggle-DeckHeaderDoubleClick {
    if($null -ne $script:DeckResizeSession){return}
    $script:DeckHeaderDragOrigin = $null
    Hide-DeckHoverPopup
    if($script:Tucked) {
        $now = Get-Date
        foreach($a in @($script:Alerts)) {
            if(!$a.ExpireAt){continue}
            $from=$script:TuckStarted
            if($a.AddedAt -and $a.AddedAt -gt $from){$from=$a.AddedAt}
            if($from){$a.ExpireAt=$a.ExpireAt.Add($now-$from)}
        }
        $script:Tucked=$false
        $script:TuckStarted=$null
        $script:DeckGrowthMode='auto'
        $script:DeckHeight=0
        $script:DeckScrollOffset=0
        Render-Expanded
    } else {
        $script:Tucked=$true
        $script:TuckStarted=Get-Date
        Render-Tucked
    }
    Save-DeckPosition
}
function Enable-DeckDrag {
    param($Control)
    if(!$Control){return}
    $Control.Cursor = [System.Windows.Forms.Cursors]::SizeAll
    $Control.Add_MouseDown({
        param($sender,$e)
        if($e.Button -ne [System.Windows.Forms.MouseButtons]::Left){return}
        if($e.Clicks -gt 1){$script:DeckHeaderDragOrigin=$null;return}
        $p=[System.Windows.Forms.Cursor]::Position
        $script:DeckHeaderDragOrigin=[pscustomobject]@{X=[int]$p.X;Y=[int]$p.Y}
    })
    $Control.Add_MouseMove({
        param($sender,$e)
        if($null -eq $script:DeckHeaderDragOrigin){return}
        if(([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -eq [System.Windows.Forms.MouseButtons]::None){
            $script:DeckHeaderDragOrigin=$null;return
        }
        $p=[System.Windows.Forms.Cursor]::Position
        if([Math]::Abs($p.X-$script:DeckHeaderDragOrigin.X)+[Math]::Abs($p.Y-$script:DeckHeaderDragOrigin.Y) -lt 6){return}
        $script:DeckHeaderDragOrigin=$null
        [void][ShinySlackDeckDragV1]::ReleaseCapture()
        [void][ShinySlackDeckDragV1]::SendMessage($form.Handle,0x00A1,[IntPtr]2,[IntPtr]::Zero)
        Clamp-DeckPosition
        Save-DeckPosition
    })
    $Control.Add_MouseUp({$script:DeckHeaderDragOrigin=$null})
    $Control.Add_DoubleClick({Toggle-DeckHeaderDoubleClick})
}
# Icon glyphs use Windows' built-in Segoe MDL2 Assets font.
function Set-DeckIcon {
    param($Button,[string]$Glyph,[string]$Accessible)
    $Button.Text=$Glyph
    $Button.Font=New-Object Drawing.Font('Segoe MDL2 Assets',11,[Drawing.FontStyle]::Regular)
    $Button.AccessibleName=$Accessible
    $Button.TextAlign=[Drawing.ContentAlignment]::MiddleCenter
}
# SHINY-DECK-OPEN-DASHBOARD-V1
function Open-ShinySlackDashboard {

    try {

        $portPath =
            Join-Path `
                $root `
                'web.port'


        if(
            Test-Path `
                -LiteralPath $portPath
        ){

            $raw =
                (
                    Get-Content `
                        -LiteralPath $portPath `
                        -Raw `
                        -ErrorAction SilentlyContinue
                ).Trim()


            $port =
                0


            if(
                [int]::TryParse(
                    $raw,
                    [ref]$port
                ) -and
                $port -gt 0
            ){

                Start-Process (
                    'http://127.0.0.1:{0}/' -f
                    $port
                )

                return
            }
        }
    }
    catch {}


    try {

        $launcher =
            Join-Path `
                $root `
                'Start-ShinySlack.ps1'


        if(
            Test-Path `
                -LiteralPath $launcher
        ){

            $ps =
                Join-Path `
                    $env:SystemRoot `
                    'System32\WindowsPowerShell\v1.0\powershell.exe'


            Start-Process `
                -FilePath $ps `
                -ArgumentList @(
                    '-NoProfile',
                    '-ExecutionPolicy','Bypass',
                    '-File',$launcher
                ) |
            Out-Null
        }
    }
    catch {}
}

# SHINY-DECK-REBUILD-V1: Deck volume settings shared with dashboard.
$script:DeckVolumeButton=$null
$script:DeckVolumePanel=$null
$script:DeckVolumeSlider=$null
$script:DeckVolumeValue=$null
$script:DeckVolumeEnabled=$true
$script:DeckVolumePercent=100
$script:DeckVolumeReadAt=[datetime]::MinValue
$script:DeckVolumeDragging=$false
# SHINY-DECK-VOLUME-WINDOW-FIX-V1
$script:DeckVolumeWindow=$null
function Position-DeckVolumeWindow {
    if(!$script:DeckVolumeWindow -or $script:DeckVolumeWindow.IsDisposed){return}
    if(!$script:DeckVolumeButton -or $script:DeckVolumeButton.IsDisposed){return}
    $origin=$script:DeckVolumeButton.PointToScreen((New-Object Drawing.Point(0,0)))
    $bounds=[System.Windows.Forms.Screen]::FromPoint($origin).WorkingArea
    $popup=$script:DeckVolumeWindow
    $left=[int]$origin.X + $script:DeckVolumeButton.Width - $popup.Width
    $left=[Math]::Max($bounds.Left+4,[Math]::Min($left,$bounds.Right-$popup.Width-4))
    $below=[int]$origin.Y + $script:DeckVolumeButton.Height + 6
    $above=[int]$origin.Y - $popup.Height - 6
    $top=if($below+$popup.Height -le $bounds.Bottom-4){$below}else{$above}
    $top=[Math]::Max($bounds.Top+4,[Math]::Min($top,$bounds.Bottom-$popup.Height-4))
    $popup.Location=New-Object Drawing.Point($left,$top)
}
function Hide-DeckVolumeWindow {
    if($script:DeckVolumeWindow -and !$script:DeckVolumeWindow.IsDisposed){
        $script:DeckVolumeWindow.Hide()
    }
    $script:DeckVolumeDragging=$false
}
function Toggle-DeckVolumeWindow {
    if(!$script:DeckVolumeWindow -or $script:DeckVolumeWindow.IsDisposed){return}
    if($script:DeckVolumeWindow.Visible){Hide-DeckVolumeWindow;return}
    Read-DeckVolume
    Update-DeckVolumeVisual
    Position-DeckVolumeWindow
    # Modeless, reusable Form: no ContextMenuStrip, no disposal on hide.
    $script:DeckVolumeWindow.Show($form)
    $script:DeckVolumeWindow.BringToFront()
}
function Read-DeckVolume {
    $config=Join-Path $root 'channel-routes.json'
    if(!(Test-Path -LiteralPath $config)){return}
    try {
        $cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $script:DeckVolumeEnabled=($null -eq $cfg.enabled -or [bool]$cfg.enabled)
        $v=if($null -eq $cfg.volume){1.0}else{[double]$cfg.volume}
        $script:DeckVolumePercent=[int][Math]::Round([Math]::Min(1.0,[Math]::Max(0.0,$v))*100)
    } catch {} # Ignore partial config write by other components; retry next tick.
}
# SHINY-DECK-VOLUME-SAVE-V2: reliable commit and visible diagnostic on failure.
function Write-DeckVolume {
    param([int]$Percent)
    $Percent=[int][Math]::Min(100,[Math]::Max(0,$Percent))
    $config=Join-Path $root 'channel-routes.json'
    $errorLog=Join-Path $root 'deck-volume-save.error.log'
    if(!(Test-Path -LiteralPath $config)){
        try {Add-Content -LiteralPath $errorLog -Value ('{0} Missing channel-routes.json' -f (Get-Date -Format o))}catch{}
        return
    }
    $temp=$config+'.deck-'+[guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$config+'.deck-save.backup'
    $lastError=$null
    try {
        # Preserve every property except volume and enabled. Never replace
        # route or deep-link configuration with a partial object.
        $cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if($null -eq $cfg.PSObject.Properties['volume']){
            $cfg | Add-Member -NotePropertyName 'volume' -NotePropertyValue 1.0
        }
        if($null -eq $cfg.PSObject.Properties['enabled']){
            $cfg | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true
        }
        $cfg.volume=[double]($Percent / 100.0)
        $cfg.enabled=($Percent -gt 0)
        $updated=$cfg | ConvertTo-Json -Depth 32 -ErrorAction Stop
        [IO.File]::WriteAllText($temp,$updated,(New-Object Text.UTF8Encoding($false)))
        # File.Replace with an actual backup; Windows can reject a null
        # backup path on some configurations. Preserve recoverability.
        for($attempt=1;$attempt -le 3;$attempt++){
            try {
                if(Test-Path -LiteralPath $config){
                    [IO.File]::Replace($temp,$config,$backup)
                } else {
                    Move-Item -LiteralPath $temp -Destination $config -ErrorAction Stop
                }
                $lastError=$null
                break
            } catch {
                $lastError=$_
                if($attempt -lt 3){Start-Sleep -Milliseconds 80}
            }
        }
        if($lastError){throw $lastError}
        # Verify on disk, do not mislead the user with a falsely saved slider.
        $saved=Get-Content -LiteralPath $config -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $savedPercent=[int][Math]::Round(([double]$saved.volume)*100)
        if($savedPercent -ne $Percent -or ([bool]$saved.enabled) -ne ($Percent -gt 0)){
            throw ('Save verification mismatch: wanted {0}%, disk reports {1}%' -f $Percent,$savedPercent)
        }
        $script:DeckVolumePercent=$Percent
        $script:DeckVolumeEnabled=($Percent -gt 0)
        $script:DeckVolumeReadAt=Get-Date
        Update-DeckVolumeVisual
    } catch {
        $message=$_.Exception.Message
        try {Add-Content -LiteralPath $errorLog -Value ('{0} requested={1}% {2}' -f (Get-Date -Format o),$Percent,$message) -Encoding UTF8} catch {}
        # Keep the chosen value on screen briefly; the periodic refresh can
        # reflect the actual disk state later. Most importantly, surface the
        # failure instead of silently snapping back with no explanation.
        $script:DeckVolumeReadAt=Get-Date
        try {
            if($script:DeckVolumeValue -and !$script:DeckVolumeValue.IsDisposed){
                $script:DeckVolumeValue.Text='SAVE ERROR'
                $script:DeckVolumeValue.ForeColor=[Drawing.Color]::FromArgb(255,99,119)
            }
        } catch {}
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Update-DeckVolumeVisual {
    $muted=(-not $script:DeckVolumeEnabled -or $script:DeckVolumePercent -le 0)
    $warning=($muted -or $script:DeckVolumePercent -le 20)
    $color=if($warning){[Drawing.Color]::FromArgb(255,99,119)}else{[Drawing.Color]::FromArgb(85,216,255)}
    if($script:DeckVolumeButton -and !$script:DeckVolumeButton.IsDisposed){
        $script:DeckVolumeButton.ForeColor=$color
        $script:DeckVolumeButton.Text=if($muted){[string][char]0xE74F}else{[string][char]0xE767}
    }
    if($script:DeckVolumeValue -and !$script:DeckVolumeValue.IsDisposed){
        $script:DeckVolumeValue.Text=if($muted){'MUTED'}else{"$($script:DeckVolumePercent)%"}
        $script:DeckVolumeValue.ForeColor=$color
    }
    if($script:DeckVolumeSlider -and !$script:DeckVolumeSlider.IsDisposed){$script:DeckVolumeSlider.Invalidate()}
}
function Set-DeckVolumeFromMouse {
    param($Control,[int]$X)
    if(!$Control -or $Control.Width -le 24){return}
    # Update the drawing while dragging; commit once on mouse release.
    $value=[int][Math]::Round(([Math]::Min($Control.Width-12,[Math]::Max(12,$X))-12)*100.0/($Control.Width-24))
    $script:DeckVolumePercent=$value
    $script:DeckVolumeEnabled=($value -gt 0)
    Update-DeckVolumeVisual
}
function Add-DeckInlineVolume {
    param([int]$Left,[int]$Top)
    # Kept as the existing render entry point. Create only ONE reusable
    # modeless Form, independent of the resizable deck's clipped client area.
    if($script:DeckVolumeWindow -and !$script:DeckVolumeWindow.IsDisposed){return}
    $popup=New-Object System.Windows.Forms.Form
    $popup.Name='ShinySlackVolumeWindow'
    $popup.FormBorderStyle=[System.Windows.Forms.FormBorderStyle]::None
    $popup.ShowInTaskbar=$false
    $popup.StartPosition=[System.Windows.Forms.FormStartPosition]::Manual
    $popup.TopMost=$true
    $popup.Width=254
    $popup.Height=70
    $popup.BackColor=[Drawing.Color]::FromArgb(15,21,32)
    $popup.KeyPreview=$true
    $popup.Add_KeyDown({param($sender,$e)
        if($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape){Hide-DeckVolumeWindow}
    })
    $panel=New-Object System.Windows.Forms.Panel
    $panel.Name='DeckVolumeSurface'
    $panel.Dock=[System.Windows.Forms.DockStyle]::Fill
    $panel.BackColor=$popup.BackColor
    $panel.BorderStyle=[System.Windows.Forms.BorderStyle]::FixedSingle
    $name=New-Object System.Windows.Forms.Label
    $name.Text='ROUTER VOLUME';$name.Left=10;$name.Top=6;$name.Width=145;$name.Height=19
    $name.Font=New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
    $name.ForeColor=$script:AlertVisual.Muted
    $value=New-Object System.Windows.Forms.Label
    $value.Left=174;$value.Top=6;$value.Width=65;$value.Height=19
    $value.TextAlign='MiddleRight'
    $value.Font=New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
    $slider=New-Object System.Windows.Forms.Panel
    $slider.Name='DeckVolumeTrack';$slider.Left=8;$slider.Top=32;$slider.Width=232;$slider.Height=28
    $slider.Cursor=[System.Windows.Forms.Cursors]::Hand
    $slider.BackColor=$panel.BackColor
    $slider.Add_Paint({
        param($sender,$e)
        $g=$e.Graphics
        $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $p=[Math]::Min(100,[Math]::Max(0,$script:DeckVolumePercent))
        $alert=(-not $script:DeckVolumeEnabled -or $p -le 20)
        $fill=if($alert){[Drawing.Color]::FromArgb(255,99,119)}else{[Drawing.Color]::FromArgb(85,216,255)}
        $x=12+[int][Math]::Round(($sender.Width-24)*$p/100.0)
        $bg=New-Object Drawing.Pen -ArgumentList @([Drawing.Color]::FromArgb(54,66,84),4)
        $fg=New-Object Drawing.Pen -ArgumentList @($fill,4)
        $brush=New-Object Drawing.SolidBrush -ArgumentList @($fill)
        try {
            $g.DrawLine($bg,12,14,$sender.Width-12,14)
            if($x -gt 12){$g.DrawLine($fg,12,14,$x,14)}
            $g.FillEllipse($brush,$x-7,7,14,14)
        } finally {$bg.Dispose();$fg.Dispose();$brush.Dispose()}
    })
    $slider.Add_MouseDown({param($sender,$e)
        if($e.Button -ne [System.Windows.Forms.MouseButtons]::Left){return}
        $script:DeckVolumeDragging=$true
        Set-DeckVolumeFromMouse $sender $e.X
        $sender.Capture=$true
    })
    $slider.Add_MouseMove({param($sender,$e)
        if(!$script:DeckVolumeDragging){return}
        if(($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne [System.Windows.Forms.MouseButtons]::Left){return}
        Set-DeckVolumeFromMouse $sender $e.X
    })
    $slider.Add_MouseUp({param($sender,$e)
        if(!$script:DeckVolumeDragging){return}
        Set-DeckVolumeFromMouse $sender $e.X
        $script:DeckVolumeDragging=$false
        $sender.Capture=$false
        Write-DeckVolume -Percent $script:DeckVolumePercent
    })
    $panel.Controls.Add($name);$panel.Controls.Add($value);$panel.Controls.Add($slider)
    $popup.Controls.Add($panel)
    $script:DeckVolumeWindow=$popup
    $script:DeckVolumePanel=$panel
    $script:DeckVolumeSlider=$slider
    $script:DeckVolumeValue=$value
    Read-DeckVolume
    Update-DeckVolumeVisual
}
function Render-Tucked {
    Hide-DeckVolumeWindow
    $form.SuspendLayout()

    try {

        $script:ActiveDeckScrollHandler =
            $null


        $form.Controls.Clear()
        $form.AutoScroll = $false

        # SHINY-DECK-CANONICAL-HEADER-V1

        if($script:LastLayoutDirection -eq 'up' -and $form.Visible){
            $form.Top = $form.Bottom - 40
        }
        $script:LastLayoutDirection = 'tucked'
$form.Width =
            360

        $form.Height =
            40


        $bar =
            New-Object System.Windows.Forms.Panel

        $bar.Dock =
            'Fill'

        $bar.BackColor =
            $script:AlertVisual.HeaderSurface


        $brandRail =
            New-Object System.Windows.Forms.Panel

        $brandRail.Left =
            0

        $brandRail.Top =
            0

        $brandRail.Width =
            3

        $brandRail.Height =
            40

        $brandRail.BackColor =
            $script:AlertVisual.DefaultAccent


        $bottomLine =
            New-Object System.Windows.Forms.Panel

        $bottomLine.Left =
            0

        $bottomLine.Top =
            39

        $bottomLine.Width =
            360

        $bottomLine.Height =
            1

        $bottomLine.BackColor =
            $script:AlertVisual.Border


        $grip =
            New-Object System.Windows.Forms.Label

        $grip.Left =
            10

        $grip.Top =
            11

        $grip.Width =
            18

        $grip.Height =
            17

        $grip.Text =
            '::'

        $grip.ForeColor =
            $script:AlertVisual.Meta

        $grip.Font =
            New-Object Drawing.Font(
                'Consolas',
                9,
                [Drawing.FontStyle]::Bold
            )


        $title =
            New-Object System.Windows.Forms.Label

        $title.Left =
            31

        $title.Top =
            10

        $title.Width =
            111

        $title.Height =
            19

        $title.Text =
            ('ShinySlack ' + [string][char]0x2728)

        $title.ForeColor =
            $script:AlertVisual.Text        # SHINY-DECK-TITLE-GLOW-CYCLE-V1: these title controls get recreated on redraw.
        $script:DeckGlowTitle = $title
        $title.Add_Paint({
            param($sender,$e)
            try {
                if($sender.IsDisposed -or !$sender.Text){return}
                $g=$e.Graphics
                $oldSmoothing=$g.SmoothingMode
                $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $accent=$script:DeckGlowColor
                if($null -eq $accent){$accent=$script:AlertVisual.DefaultAccent}
                # A soft, low-opacity halo, then a crisp near-white title.
                # Draw on the Label's paint surface; no popup/window lifecycle involved.
                $halo=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(39,$accent.R,$accent.G,$accent.B))
                $core=[Drawing.SolidBrush]::new($sender.ForeColor)
                try {
                    foreach($o in @(@(-2,0),@(2,0),@(0,-1),@(0,1))){
                        $g.DrawString($sender.Text,$sender.Font,$halo,[single]([int]$o[0]),[single]([int]$o[1]))
                    }
                    $g.DrawString($sender.Text,$sender.Font,$core,[single]0,[single]0)
                } finally { $halo.Dispose();$core.Dispose();$g.SmoothingMode=$oldSmoothing }
            } catch { }
        })

        $title.Font =
            New-Object Drawing.Font(
                'Segoe UI',
                9,
                [Drawing.FontStyle]::Bold
            )


        $countText =
            if($script:Alerts.Count -eq 1){
                '1 alert'
            }
            else {
                "$($script:Alerts.Count) alerts"
            }


        $count =
            New-Object System.Windows.Forms.Label

        $count.Left =
            145

        $count.Top =
            9

        $count.Width =
            76

        $count.Height =
            22

        $count.Text =
            $countText

        $count.TextAlign =
            'MiddleCenter'

        $count.ForeColor =
            $script:AlertVisual.Muted

        $count.Font =
            New-Object Drawing.Font(
                'Consolas',
                8.25
            )


        $dashboard =
            New-Button '' 32
        Set-DeckIcon $dashboard ([string][char]0xE80F) 'Open dashboard'

        $dashboard.Left =
            278

        $dashboard.Top =
            6

        $dashboard.Height =
            28

        Set-RoundedRegion `
            $dashboard `
            8

        $dashboard.Add_Click({
            Open-ShinySlackDashboard
        })


        $plus =
            New-Button '' 28
        Set-DeckIcon $plus ([string][char]0xE8A3) 'Expand deck'

        $plus.Left =
            326

        $plus.Top =
            6

        $plus.Height =
            28

        $plus.ForeColor =
            $script:AlertVisual.DefaultAccent

        Set-RoundedRegion `
            $plus `
            8


        $plus.Add_Click({

            $now =
                Get-Date


            foreach(
                $a in
                @($script:Alerts)
            ){

                if(!$a.ExpireAt){
                    continue
                }


                $pauseFrom =
                    $script:TuckStarted


                if(
                    $a.AddedAt -and
                    $a.AddedAt -gt $pauseFrom
                ){
                    $pauseFrom =
                        $a.AddedAt
                }


                if($pauseFrom){

                    $a.ExpireAt =
                        $a.ExpireAt.Add(
                            $now -
                            $pauseFrom
                        )
                }
            }


            $script:Tucked =
                $false

            $script:TuckStarted =
                $null


            Render-Expanded
        })


        foreach(
            $dragSurface in
            @(
                $bar,
                $grip,
                $title,
                $count
            )
        ){

            Enable-DeckDrag `
                $dragSurface
        }


        $bar.Controls.Add(
            $brandRail
        )

        $bar.Controls.Add(
            $bottomLine
        )

        $bar.Controls.Add(
            $grip
        )

        $bar.Controls.Add(
            $title
        )

        $bar.Controls.Add(
            $count
        )

        $bar.Controls.Add(
            $dashboard
        )

        $bar.Controls.Add(
            $plus
        )

        # SHINY-DECK-COMPACT-VOLUME-279-V1
        # Remains visible in compact mode: critical muted-state indicator.
        $compactVolume = New-Button '' 30
        Set-DeckIcon $compactVolume ([string][char]0xE767) 'Router notification volume'
        $compactVolume.Left = 237
        $compactVolume.Top = 6
        $compactVolume.Height = 28
        Set-RoundedRegion $compactVolume 8
        $compactVolume.Add_Click({ Toggle-DeckVolumeWindow })
        $script:DeckVolumeButton = $compactVolume
        $bar.Controls.Add($compactVolume)
        Set-DeckHoverDescriptor $compactVolume 'Notification volume. Red means muted or 20% or lower.'
        Read-DeckVolume
        Update-DeckVolumeVisual

        $form.Controls.Add(
            $bar
        )
        Set-DeckHoverDescriptor $dashboard 'Open the ShinySlack dashboard'
        Set-DeckHoverDescriptor $plus 'Show the alert cards'



        Position-Form
        Set-RoundedRegion $form 12


        if(!$form.Visible){
            $form.Show()
        }
    }
    finally {

        $form.ResumeLayout(
            $true
        )
    }
}

# SHINY-SLACK-DESKTOP-JUMP-V1

function Convert-ToSendKeysLiteral {
    param([string]$Text)

    $sb =
        New-Object Text.StringBuilder

    foreach($ch in $Text.ToCharArray()){

        switch($ch){

            '+' {
                [void]$sb.Append('{+}')
            }

            '^' {
                [void]$sb.Append('{^}')
            }

            '%' {
                [void]$sb.Append('{%}')
            }

            '~' {
                [void]$sb.Append('{~}')
            }

            '(' {
                [void]$sb.Append('{(}')
            }

            ')' {
                [void]$sb.Append('{)}')
            }

            '{' {
                [void]$sb.Append('{{}')
            }

            '}' {
                [void]$sb.Append('{}}')
            }

            default {
                [void]$sb.Append($ch)
            }
        }
    }

    return $sb.ToString()
}


function Open-SlackConversation {
    param([string]$Channel)

    # SHINY-NATIVE-DEEPLINK-V2
    try {

        $channelKey =
            ([string]$Channel).Trim()


        if($channelKey.StartsWith('#')){
            $channelKey = $channelKey.Substring(1)
        }


        $configPath =
            Join-Path `
                $env:LOCALAPPDATA `
                'ShinySlack\channel-routes.json'


        if(
            $channelKey -and
            (Test-Path -LiteralPath $configPath)
        ){

            $cfg =
                Get-Content `
                    -LiteralPath $configPath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json


            if($cfg.deepLinks){

                $property =
                    $cfg.deepLinks.PSObject.Properties |
                    Where-Object {
                        $_.Name -eq $channelKey
                    } |
                    Select-Object -First 1


                if($property){

                    $team =
                        [string]$property.Value.team

                    $conversation =
                        [string]$property.Value.channel


                    if(
                        $team -and
                        $conversation
                    ){

                        Start-Process (
                            'slack://channel?team={0}&id={1}' -f
                            [Uri]::EscapeDataString($team),
                            [Uri]::EscapeDataString($conversation)
                        ) |
                        Out-Null


                        return
                    }
                }
            }
        }
    }
    catch {
        # Native link failed: fall through to existing
        # restore/focus behavior.
    }

    # Channel is intentionally ignored now.
    # Clicking any alert simply restores/focuses Slack.

    $navLog =
        Join-Path `
            $env:LOCALAPPDATA `
            'ShinySlack\persistent-alerts.nav.log'


    function NavLog {
        param([string]$Message)

        try {
            Add-Content `
                -LiteralPath $navLog `
                -Value (
                    "{0} {1}" -f
                    (Get-Date -Format 'HH:mm:ss.fff'),
                    $Message
                ) `
                -Encoding UTF8
        }
        catch {}
    }


    # SHINY-DEEP-LINK-OVERLAY-V1
    #
    # Exact native deep link when this channel has IDs configured.
    # Unlinked channels fall through to the existing focus logic.
    try {

        $channelKey =
            ([string]$Channel).Trim()


        if($channelKey.StartsWith('#')){

            $channelKey =
                $channelKey.Substring(1)
        }


        $configPath =
            Join-Path `
                $env:LOCALAPPDATA `
                'ShinySlack\channel-routes.json'


        if(
            $channelKey -and
            (Test-Path -LiteralPath $configPath)
        ){

            $cfg =
                Get-Content `
                    -LiteralPath $configPath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json


            if($cfg.deepLinks){

                $property =
                    $cfg.deepLinks.PSObject.Properties |
                    Where-Object {
                        $_.Name -eq $channelKey
                    } |
                    Select-Object -First 1


                if($property){

                    $team =
                        [string]$property.Value.team

                    $conversation =
                        [string]$property.Value.channel


                    if(
                        $team -and
                        $conversation
                    ){

                        $uri =
                            "slack://channel?team={0}&id={1}" -f
                            [Uri]::EscapeDataString($team),
                            [Uri]::EscapeDataString($conversation)


                        NavLog (
                            "DEEPLINK channel=#{0} uri={1}" -f
                            $channelKey,
                            $uri
                        )


                        Start-Process `
                            $uri |
                            Out-Null


                        return
                    }
                }
            }
        }
    }
    catch {

        NavLog (
            'DEEPLINK_ERROR ' +
            $_.Exception.Message
        )
    }

    try {
        if(-not ('ShinySlackWindowFocusV2' -as [type])){

            Add-Type @"
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class ShinySlackWindowFocusV2
{
    public class WindowInfo
    {
        public IntPtr Handle;
        public int ProcessId;
        public string Title;
        public int Score;
    }

    public delegate bool EnumWindowsProc(
        IntPtr hWnd,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(
        EnumWindowsProc lpEnumFunc,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(
        IntPtr hWnd
    );

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(
        IntPtr hWnd
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder lpString,
        int nMaxCount
    );

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint lpdwProcessId
    );

    [DllImport("user32.dll")]
    public static extern bool IsIconic(
        IntPtr hWnd
    );

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(
        IntPtr hWnd,
        int nCmdShow
    );

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(
        IntPtr hWnd
    );

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(
        IntPtr hWnd
    );

    public static WindowInfo FindSlackWindow()
    {
        var matches = new List<WindowInfo>();

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd))
                return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);

            if (pid == 0)
                return true;

            Process process;

            try
            {
                process = Process.GetProcessById((int)pid);
            }
            catch
            {
                return true;
            }

            if (!string.Equals(
                    process.ProcessName,
                    "slack",
                    StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            int len = GetWindowTextLength(hWnd);

            if (len <= 0)
                return true;

            var sb = new StringBuilder(len + 1);
            GetWindowText(hWnd, sb, sb.Capacity);

            string title = sb.ToString();

            if (string.IsNullOrWhiteSpace(title))
                return true;

            // Never select Slack's notification/helper window.
            if (title.IndexOf(
                    "app://resources/notifications.html",
                    StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }

            int score = 10;

            if (title.IndexOf(
                    "Slack",
                    StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score += 100;
            }

            if (title.IndexOf(
                    "Channel",
                    StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score += 40;
            }

            if (title.IndexOf(
                    "Direct message",
                    StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score += 40;
            }

            if (title.IndexOf(
                    "Amazon",
                    StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score += 25;
            }

            matches.Add(
                new WindowInfo {
                    Handle = hWnd,
                    ProcessId = (int)pid,
                    Title = title,
                    Score = score
                }
            );

            return true;

        }, IntPtr.Zero);


        WindowInfo best = null;

        foreach(var item in matches)
        {
            if (best == null || item.Score > best.Score)
                best = item;
        }

        return best;
    }


    public static bool RestoreSlack(
        WindowInfo window
    )
    {
        if (window == null)
            return false;

        // SW_RESTORE = 9
        if (IsIconic(window.Handle))
            ShowWindowAsync(window.Handle, 9);
        else
            ShowWindowAsync(window.Handle, 5);

        BringWindowToTop(window.Handle);

        return SetForegroundWindow(
            window.Handle
        );
    }
}
"@
        }


        $window =
            [ShinySlackWindowFocusV2]::FindSlackWindow()


        if(!$window){
            NavLog 'ABORT no-slack-workspace-window'
            return
        }


        NavLog (
            "FOUND pid={0} title='{1}' score={2}" -f
            $window.ProcessId,
            $window.Title,
            $window.Score
        )


        $result =
            [ShinySlackWindowFocusV2]::RestoreSlack(
                $window
            )


        NavLog (
            "RESTORE result={0}" -f
            $result
        )
    }
    catch {
        NavLog (
            'ERROR ' +
            $_.Exception.Message
        )
    }
}

function Set-RoundedRegion {
    param(
        $Control,
        [int]$Radius = 14
    )

    if(
        !$Control -or
        $Control.Width -lt 2 -or
        $Control.Height -lt 2
    ){
        return
    }

    $d = $Radius * 2

    $path =
        New-Object System.Drawing.Drawing2D.GraphicsPath

    $path.StartFigure()
    $path.AddArc(0,0,$d,$d,180,90)
    $path.AddArc($Control.Width-$d,0,$d,$d,270,90)

    $path.AddArc(
        $Control.Width-$d,
        $Control.Height-$d,
        $d,
        $d,
        0,
        90
    )

    $path.AddArc(
        0,
        $Control.Height-$d,
        $d,
        $d,
        90,
        90
    )

    $path.CloseFigure()

    $Control.Region =
        New-Object Drawing.Region($path)
}

# SHINY-DECK-CORNER-RESIZE-V1
$script:DeckResizeSession = $null
$script:DeckResizePoller = New-Object System.Windows.Forms.Timer
$script:DeckResizePoller.Interval = 24
$script:DeckResizePoller.Add_Tick({
    $session=$script:DeckResizeSession
    if($null -eq $session){$script:DeckResizePoller.Stop();return}
    try {
        $mouse=[System.Windows.Forms.Control]::MouseButtons
        if(($mouse -band [System.Windows.Forms.MouseButtons]::Left) -eq [System.Windows.Forms.MouseButtons]::None){
            $script:DeckResizePoller.Stop()
            $script:DeckResizeSession=$null
            $bounds=$form.Bounds
            $script:DeckWidth=[int]$bounds.Width
            $script:DeckHeight=[int]$bounds.Height
            $script:DeckGrowthMode='auto'
            $script:DeckGrowthArmedCount=[int]$script:NextId
            # One full redraw AFTER dragging, rather than every 90ms during dragging.
            $script:OverrideAnchorY=if($script:ExpansionDirection -eq 'up'){$bounds.Bottom-40}else{$bounds.Top}
            Render-Expanded
            $form.Left=[int]$bounds.Left
            $form.Top=[int]$bounds.Top
            Clamp-DeckPosition
            Save-DeckPosition
            return
        }
        $p=[System.Windows.Forms.Cursor]::Position
        $dx=[int]$p.X - $session.X
        $dy=[int]$p.Y - $session.Y
        $left=[int]$session.Left;$top=[int]$session.Top
        $right=[int]$session.Right;$bottom=[int]$session.Bottom
        if($session.Corner.EndsWith('L')){$left=[Math]::Min($right-460,[Math]::Max($right-850,$left+$dx))}
        else{$right=[Math]::Min($left+850,[Math]::Max($left+460,$right+$dx))}
        if($session.Corner.StartsWith('T')){$top=[Math]::Min($bottom-110,[Math]::Max($bottom-700,$top+$dy))}
        else{$bottom=[Math]::Min($top+700,[Math]::Max($top+110,$bottom+$dy))}
        $w=[int]($right-$left);$h=[int]($bottom-$top)
        if($form.Left -ne $left -or $form.Top -ne $top -or $form.Width -ne $w -or $form.Height -ne $h){
            $form.SetBounds($left,$top,$w,$h)
        }
    } catch {
        $script:DeckResizePoller.Stop()
        $script:DeckResizeSession=$null
        try {Render-Expanded;Save-DeckPosition} catch {}
    }
})
function Add-DeckCornerHandles {
    # Only expanded view is resizable. Header drag surfaces remain untouched.
    foreach($corner in @('TL','TR','BL','BR')){
        $hit=New-Object System.Windows.Forms.Panel
        $hit.Name='DeckResize'+$corner
        $hit.Width=14;$hit.Height=14
        $hit.Left=if($corner.EndsWith('L')){0}else{$form.ClientSize.Width-14}
        $hit.Top=if($corner.StartsWith('T')){0}else{$form.ClientSize.Height-14}
        # SHINY-2710-CORNER-CLIP-V2: the top handle overlays the header.
        # Give it the header's surface rather than painting a dark square.
        $hit.BackColor=if($corner.StartsWith('T')){$script:AlertVisual.HeaderSurface}else{$script:AlertVisual.PageBackground}
        $hit.Cursor=if($corner -in @('TL','BR')){[System.Windows.Forms.Cursors]::SizeNWSE}else{[System.Windows.Forms.Cursors]::SizeNESW}
        $hit.AccessibleName='Resize deck from '+$corner+' corner'
        $hit.Tag=$corner
        $hit.Add_MouseDown({
            param($sender,$e)
            if($e.Button -ne [System.Windows.Forms.MouseButtons]::Left){return}
            if($null -ne $script:DeckResizeSession){return}
            $p=[System.Windows.Forms.Cursor]::Position
            $b=$form.Bounds
            $script:DeckResizeSession=[pscustomobject]@{
                Corner=[string]$sender.Tag;X=[int]$p.X;Y=[int]$p.Y
                Left=[int]$b.Left;Top=[int]$b.Top;Right=[int]$b.Right;Bottom=[int]$b.Bottom
            }
            $script:DeckResizePoller.Start()
        })
        $form.Controls.Add($hit)
        $hit.BringToFront()
    }
}
function Render-Expanded {
    $form.SuspendLayout()

    try {
        $anchorY = if($script:LastLayoutDirection -eq 'up' -and $form.Visible){
            $form.Bottom - 40
        }else{ $form.Top }
        if($null -ne $script:OverrideAnchorY){
            $anchorY = [int]$script:OverrideAnchorY
            $script:OverrideAnchorY = $null
        }
        $form.Controls.Clear()
        # SHINY-DECK-CUSTOM-SCROLL-V1
        $form.AutoScroll = $false
        $form.Width = $script:DeckWidth

        $items = @(
            $script:Alerts |
            Sort-Object AddedAt -Descending
        )

        if($items.Count -eq 0){
            # Empty is a real state, not a reason to hide the deck.
            $script:DeckScrollOffset = 0
        }


        # =====================================================
        # HEADER
        # Canonical ShinySlack deck chrome.
        # =====================================================

        $header =
            New-Object System.Windows.Forms.Panel

        $header.Left =
            0

        $header.Top =
            0

        $header.Width =
            $script:DeckWidth

        $header.Height =
            40

        $header.BackColor =
            $script:AlertVisual.HeaderSurface

        Set-RoundedRegion `
            $header `
            10


        $brandRail =
            New-Object System.Windows.Forms.Panel

        $brandRail.Left =
            0

        $brandRail.Top =
            0

        $brandRail.Width =
            3

        $brandRail.Height =
            40

        $brandRail.BackColor =
            $script:AlertVisual.DefaultAccent


        $bottomLine =
            New-Object System.Windows.Forms.Panel

        $bottomLine.Left =
            0

        $bottomLine.Top =
            39

        $bottomLine.Width =
            $script:DeckWidth

        $bottomLine.Height =
            1

        $bottomLine.BackColor =
            $script:AlertVisual.Border


        $dragGrip =
            New-Object System.Windows.Forms.Label

        $dragGrip.Left =
            10

        $dragGrip.Top =
            11

        $dragGrip.Width =
            18

        $dragGrip.Height =
            17

        $dragGrip.Text =
            '::'

        $dragGrip.ForeColor =
            $script:AlertVisual.Meta

        $dragGrip.Font =
            New-Object Drawing.Font(
                'Consolas',
                9,
                [Drawing.FontStyle]::Bold
            )


        $title =
            New-Object System.Windows.Forms.Label

        $title.Left =
            32

        $title.Top =
            10

        $title.Width =
            111

        $title.Height =
            19

        $title.Text =
            ('ShinySlack ' + [string][char]0x2728)

        $title.ForeColor =
            $script:AlertVisual.Text        # SHINY-DECK-TITLE-GLOW-CYCLE-V1: these title controls get recreated on redraw.
        $script:DeckGlowTitle = $title
        $title.Add_Paint({
            param($sender,$e)
            try {
                if($sender.IsDisposed -or !$sender.Text){return}
                $g=$e.Graphics
                $oldSmoothing=$g.SmoothingMode
                $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $accent=$script:DeckGlowColor
                if($null -eq $accent){$accent=$script:AlertVisual.DefaultAccent}
                # A soft, low-opacity halo, then a crisp near-white title.
                # Draw on the Label's paint surface; no popup/window lifecycle involved.
                $halo=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(39,$accent.R,$accent.G,$accent.B))
                $core=[Drawing.SolidBrush]::new($sender.ForeColor)
                try {
                    foreach($o in @(@(-2,0),@(2,0),@(0,-1),@(0,1))){
                        $g.DrawString($sender.Text,$sender.Font,$halo,[single]([int]$o[0]),[single]([int]$o[1]))
                    }
                    $g.DrawString($sender.Text,$sender.Font,$core,[single]0,[single]0)
                } finally { $halo.Dispose();$core.Dispose();$g.SmoothingMode=$oldSmoothing }
            } catch { }
        })

        $title.Font =
            New-Object Drawing.Font(
                'Segoe UI',
                9,
                [Drawing.FontStyle]::Bold
            )


        $countText =
            if($items.Count -eq 1){
                '1 alert'
            }
            else {
                "$($items.Count) alerts"
            }


        $count =
            New-Object System.Windows.Forms.Label

        $count.Left = 145
        $count.Top = 9
        $count.Width = 52

        $count.Height =
            22

        $count.Text =
            $countText

        $count.TextAlign =
            'MiddleCenter'

        $count.ForeColor =
            $script:AlertVisual.Muted

        $count.Font =
            New-Object Drawing.Font(
                'Consolas',
                8.25
            )


        $dashboard = New-Button '' 30
        Set-DeckIcon $dashboard ([string][char]0xE80F) 'Open dashboard'
        $dashboard.Left = ($script:DeckWidth - 208)

        $dashboard.Top =
            6

        $dashboard.Height =
            28

        Set-RoundedRegion `
            $dashboard `
            8

        $dashboard.Add_Click({
            Open-ShinySlackDashboard
        })


        $minus =
            New-Button '' 28
        Set-DeckIcon $minus ([string][char]0xE921) 'Minimize deck'

        $minus.Left =
            ($script:DeckWidth - 76)

        $minus.Top =
            6

        $minus.Height =
            28

        Set-RoundedRegion `
            $minus `
            8


        $minus.Add_Click({

            $script:Tucked =
                $true

            $script:TuckStarted =
                Get-Date

            Render-Tucked
        })


        $closeAll =
            New-Button '' 28
        Set-DeckIcon $closeAll ([string][char]0xE8BB) 'Hide deck'

        $closeAll.Left =
            ($script:DeckWidth - 43)

        $closeAll.Top =
            6

        $closeAll.Height =
            28

        Set-RoundedRegion `
            $closeAll `
            8


        $closeAll.Add_Click({
            # X hides the deck but retains alerts and current layout.
            $script:DeckHiddenAt = Get-Date
            Remove-Item -LiteralPath (Join-Path $root 'deck-visible.heartbeat') -Force -ErrorAction SilentlyContinue
            Hide-DeckVolumeWindow
            $form.Hide()
        })        # SHINY-DECK-FINISH-RESIZE-DIRECTION-V1
        $direction = New-Button '' 28
        Set-DeckIcon $direction $(if($script:ExpansionDirection -eq 'up'){[string][char]0xE70E}else{[string][char]0xE70D}) 'Expansion direction'
        $direction.Left = $script:DeckWidth - 109
        $direction.Top = 6
        $direction.Height = 28
        $direction.ForeColor = $script:AlertVisual.DefaultAccent
        $direction.Tag = 'Expand alerts upward or downward'
        Set-RoundedRegion $direction 8
        $direction.Add_Click({
            $script:ExpansionDirection = if($script:ExpansionDirection -eq 'up'){'down'}else{'up'}
            Render-Expanded
            Save-DeckPosition
        })
        # Resizing is available from all four corners.

        $header.Controls.Add(
            $brandRail
        )

        $header.Controls.Add(
            $bottomLine
        )

        $header.Controls.Add(
            $dragGrip
        )

        $header.Controls.Add(
            $title
        )

        $header.Controls.Add(
            $count
        )

        $header.Controls.Add(
            $dashboard
        )

        $header.Controls.Add(
            $minus
        )

        $header.Controls.Add(
            $closeAll
        )
        # SHINY-DECK-COMPACT-V5
        # SHINY-DECK-THREE-WAY-GROWTH-V1
        # Cycle: auto -> one-card reset (once) -> one-card lock -> auto.
        $compactLabel = switch($script:DeckGrowthMode){
            'once'   { '1' }
            'locked' { '1L' }
            default  { 'A' }
        }
        $compact = New-Button '' 28
        Set-DeckIcon $compact $(if($script:DeckGrowthMode -eq 'locked'){[string][char]0xE72E}elseif($script:DeckGrowthMode -eq 'once'){[string][char]0xE8A3}else{[string][char]0xE90C}) ('Deck growth: '+$script:DeckGrowthMode)
        $compact.Left = $script:DeckWidth - 175
        $compact.Top = 6
        $compact.Height = 28
        $compact.ForeColor = $script:AlertVisual.DefaultAccent
        Set-RoundedRegion $compact 8
        $compact.Add_Click({
            $anchor = if($script:ExpansionDirection -eq 'up'){$form.Bottom - 40}else{$form.Top}
            switch($script:DeckGrowthMode){
                'auto' {
                    # Reset once: fit one card until a NEW alert arrives.
                    $script:DeckGrowthMode = 'once'
                    $script:DeckGrowthArmedCount = [int]$script:NextId
                    $script:DeckWidth = 460
                    $script:DeckHeight = [int][Math]::Max(110,($script:AlertVisual.CardHeight + 52))
                    $script:DeckScrollOffset = 0
                }
                'once' {
                    # Lock the one-card viewport. Keep all alerts scrollable.
                    $script:DeckGrowthMode = 'locked'
                    $script:DeckWidth = 460
                    $script:DeckHeight = [int][Math]::Max(110,($script:AlertVisual.CardHeight + 52))
                    $script:DeckScrollOffset = 0
                }
                default {
                    # Disable one-card mode and fit all current alerts.
                    $script:DeckGrowthMode = 'auto'
                    $script:DeckHeight = 0
                    $script:DeckScrollOffset = 0
                }
            }
            $script:OverrideAnchorY = [int]$anchor
            Render-Expanded
            Save-DeckPosition
        })
        $header.Controls.Add($compact)
        $compactHelp = switch($script:DeckGrowthMode){
            'once'   { 'One-card reset: next new alert restores automatic growth. Click to lock one card.' }
            'locked' { 'One-card LOCKED: new alerts scroll instead of expanding. Click for Auto.' }
            default  { 'AUTO: grow naturally with new alerts. Click to reset to one card once.' }
        }
        Set-DeckHoverDescriptor $compact $compactHelp
        $volumeButton = New-Button '' 30
        Set-DeckIcon $volumeButton ([string][char]0xE767) 'Router notification volume'
        $volumeButton.Left = $script:DeckWidth - 142
        $volumeButton.Top = 6
        $volumeButton.Height = 28
        Set-RoundedRegion $volumeButton 8
        $volumeButton.Add_Click({Toggle-DeckVolumeWindow})
        $script:DeckVolumeButton=$volumeButton
        $header.Controls.Add($volumeButton)
        Set-DeckHoverDescriptor $volumeButton 'Adjust Router volume. Red means muted or 20% or lower.'
        $header.Controls.Add($direction)
        # No visible resize icon.


        foreach(
            $dragSurface in
            @(
                $header,
                $dragGrip,
                $title,
                $count
            )
        ){

            Enable-DeckDrag `
                $dragSurface
        }


        $form.Controls.Add(
            $header
        )


        # =====================================================
        # CUSTOM CARD VIEWPORT + DARK SCROLLBAR
        # =====================================================

        $viewport =
            New-Object System.Windows.Forms.Panel

        $viewport.Left = 0
        $viewport.Top = 46
        $viewport.Width = ($script:DeckWidth - 10)
        $viewport.Height = 100

        $viewport.BackColor =
            $script:AlertVisual.PageBackground

        $viewport.AutoScroll =
            $false


        $content =
            New-Object System.Windows.Forms.Panel

        $content.Left = 0
        $content.Top = 0
        $content.Width = ($script:DeckWidth - 14)
        $content.Height = 100

        $content.BackColor =
            $script:AlertVisual.PageBackground


        $scrollRail =
            New-Object System.Windows.Forms.Panel

        $scrollRail.Left = ($script:DeckWidth - 7)
        $scrollRail.Top = 50
        $scrollRail.Width = 5
        $scrollRail.Height = 90

        $scrollRail.BackColor =
            $script:AlertVisual.HeaderSurface

        $scrollRail.Cursor =
            [Windows.Forms.Cursors]::Hand


        $scrollThumb =
            New-Object System.Windows.Forms.Panel

        $scrollThumb.Left = 0
        $scrollThumb.Top = 0
        $scrollThumb.Width = 5
        $scrollThumb.Height = 36

        $scrollThumb.BackColor =
            $script:AlertVisual.ScrollThumb

        $scrollThumb.Cursor =
            [Windows.Forms.Cursors]::SizeNS


        $scrollRail.Controls.Add(
            $scrollThumb
        )

        $viewport.Controls.Add(
            $content
        )

        $form.Controls.Add(
            $viewport
        )

        $form.Controls.Add(
            $scrollRail
        )


        # =====================================================
        # CARDS
        # =====================================================
        $top = 0
        if($items.Count -eq 0){
            $empty = New-Object System.Windows.Forms.Label
            $empty.Left = 16
            $empty.Top = 12
            $empty.Width = [Math]::Max(150,($script:DeckWidth - 48))
            $empty.Height = 38
            $empty.Text = 'No alerts yet - listening for Slack notifications'
            $empty.ForeColor = $script:AlertVisual.Muted
            $empty.Font = New-Object Drawing.Font('Segoe UI',9)
            $empty.TextAlign = 'MiddleLeft'
            $content.Controls.Add($empty)
        }


        foreach($a in $items){

            $accent =
                Get-AccentColor `
                    -Index ([int]$a.AccentIndex)


            $openSlack = {
                param($sender,$eventArgs)

                Open-SlackConversation `
                    -Channel ([string]$sender.Tag)
            }


            # -------------------------------------------------
            # BORDER SHELL
            # -------------------------------------------------

            $shell =
                New-Object System.Windows.Forms.Panel

            $shell.Left = 0
            $shell.Top = $top
            $shell.Width = ($script:DeckWidth - 14)
            $shell.Height = $script:AlertVisual.CardHeight

# SHINY-2710-CARD-ALIGN-V1
            # SHINY-2710-PARITY-V2: Keep the semantic rail vivid; quiet the
            # one-pixel shell border to match Activity's restrained outline.
            # SHINY-2710-CANDY-EDGE-V7: rounded accent backing, not a separate rail.
            # A softened event hue follows the SAME rounded outer card contour.
            $shell.BackColor = [Drawing.Color]::FromArgb(
                [int][Math]::Round($accent.R * 0.78 + $script:AlertVisual.Border.R * 0.22),
                [int][Math]::Round($accent.G * 0.78 + $script:AlertVisual.Border.G * 0.22),
                [int][Math]::Round($accent.B * 0.78 + $script:AlertVisual.Border.B * 0.22)
            )

            $shell.Tag = $a.Channel
            $shell.Cursor =
                [Windows.Forms.Cursors]::Hand

            $shell.Add_Click($openSlack)

            Set-RoundedRegion $shell $script:AlertVisual.CardRadius


            # -------------------------------------------------
            # CARD
            # -------------------------------------------------

            $card =
                New-Object System.Windows.Forms.Panel

            # Inset the card to reveal a curved 4px accent on the left.
            # Top/bottom/right remain a fine outline; no overlay or square strip.
            $card.Left = 4
            $card.Top = 1
            $card.Width = ($shell.Width - 5)
            $card.Height = ($shell.Height - 2)

            # A quiet accent wash without custom painting or gradient brushes.
            # Activity uses a dark themed inset with an accent rail.
            # SHINY-2710-ACTIVITY-PARITY-V3: Use exactly the Activity inset
            # surface. A themed accent rail already provides identity.
            $wash = 0.0
            $base = $script:AlertVisual.CardBackground
            $card.BackColor = [Drawing.Color]::FromArgb(
                [int][Math]::Round($base.R * (1-$wash) + $accent.R * $wash),
                [int][Math]::Round($base.G * (1-$wash) + $accent.G * $wash),
                [int][Math]::Round($base.B * (1-$wash) + $accent.B * $wash)
            )

            $card.Tag = $a.Channel
            $card.Cursor =
                [Windows.Forms.Cursors]::Hand

            $card.Add_Click($openSlack)

            Set-RoundedRegion $card ($script:AlertVisual.CardRadius - 1)


            # v7: no independent rail panel; shell is the curved accent.
            # -------------------------------------------------
            # CHANNEL - canonical Activity visual identity
            # Real WinForms label; do not custom-paint notification text.
            # SHINY-DECK-CHANNEL-LABEL-V2
            # -------------------------------------------------

            $channel =
                New-Object System.Windows.Forms.Label

            $channel.Left =
                18

            $channel.Top =
                10

            $channel.Width =
                ($script:DeckWidth - 164)

            $channel.Height =
                38

            $channel.Text =
                [string]$a.Channel

            $channel.TextAlign =
                'MiddleLeft'

            $channel.AutoEllipsis =
                $true

            $channel.BackColor =
                [Drawing.Color]::Transparent

            # Arcade receives a distinctive neon-cyan title; other themes stay neutral.
            $channel.ForeColor = if ($script:NativeThemeName -eq 'arcade') {
                [Drawing.ColorTranslator]::FromHtml('#7EE8FF')
            } else {
                $script:AlertVisual.Text
            }

            $channel.Font =
                New-Object Drawing.Font(
                    'Segoe UI',
                    11.25,
                    [Drawing.FontStyle]::Bold
                )

            $channel.Tag =
                $a.Channel

            $channel.Cursor =
                [Windows.Forms.Cursors]::Hand

            $channel.Add_Click(
                $openSlack
            )



            # -------------------------------------------------            # TIME
            # -------------------------------------------------

            $time =
                New-Object System.Windows.Forms.Label

            $time.Left = ($script:DeckWidth - 140)
            $time.Top = 19
            $time.Width = 74
            $time.Height = 22

            $time.TextAlign = 'MiddleRight'
            $time.Text = $a.Time.ToString('h:mm tt')
            # Arcade: pink timestamp; preserve the existing softened event
            # color calculation for Shiny, Ghost Type and Retro Cartridge.
            $time.ForeColor = if ($script:NativeThemeName -eq 'arcade') {
                [Drawing.ColorTranslator]::FromHtml('#FF8BC8')
            } else {
                [Drawing.Color]::FromArgb(
                    [int][Math]::Round($accent.R * 0.65 + $script:AlertVisual.SecondaryText.R * 0.35),
                    [int][Math]::Round($accent.G * 0.65 + $script:AlertVisual.SecondaryText.G * 0.35),
                    [int][Math]::Round($accent.B * 0.65 + $script:AlertVisual.SecondaryText.B * 0.35)
                )
            }

            $time.Font =
                New-Object Drawing.Font(
                    'Consolas',
                    8.25,
                    [Drawing.FontStyle]::Bold
                )

            $time.Tag = $a.Channel
            $time.Cursor =
                [Windows.Forms.Cursors]::Hand

            $time.Add_Click($openSlack)


            # -------------------------------------------------
            # INDIVIDUAL X = DISMISS THIS CARD ONLY
            # -------------------------------------------------

            $x =
                New-Button 'X' 28

            $x.Left = ($script:DeckWidth - 55)
            $x.Top = 19
            $x.Height = 24
            $x.Tag = $a.Id

            # Quiet, borderless dismiss affordance (Activity-style chrome).
            $x.BackColor = $card.BackColor
            $x.ForeColor = $script:AlertVisual.Muted
            $x.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $x.FlatAppearance.BorderSize = 0
            $x.FlatAppearance.MouseOverBackColor = $script:AlertVisual.HoverBackground
            $x.FlatAppearance.MouseDownBackColor = $script:AlertVisual.HoverBackground
            Set-RoundedRegion $x 8


                        Set-DeckHoverDescriptor $x 'Dismiss this alert'
$x.Add_Click({
                param($sender,$eventArgs)

                $id =
                    [int]$sender.Tag

                $target =
                    @(
                        $script:Alerts |
                        Where-Object {
                            $_.Id -eq $id
                        }
                    ) |
                    Select-Object -First 1


                if($target){

                    [void]$script:Alerts.Remove(
                        $target
                    )
                }


                Render-Expanded
            })


            $card.Controls.Add($channel)
            $card.Controls.Add($time)
            $card.Controls.Add($x)

            # v7: the shell itself supplies the curved accent backing.
            $time.BringToFront()
            $x.BringToFront()

            $shell.Controls.Add($card)
            $content.Controls.Add($shell)


            $top += ($script:AlertVisual.CardHeight + $script:AlertVisual.CardGap)
        }
                $autoHeight = [Math]::Max(110,[Math]::Min(($top + 52),700))
        $form.Height = if($script:DeckHeight -gt 0){
            [Math]::Min(700,[Math]::Max(110,[int]$script:DeckHeight))
        }else{ $autoHeight }


        # SHINY-2710-CORNER-CLIP-V2: 46px top offset means form-42
        # extended four pixels past the bottom of the rounded form.
        # Keep the card viewport inside the form for both growth directions.
        $viewport.Height =
            [Math]::Max(24,($form.Height - 46))


        $content.Height =
            [Math]::Max(
                $top,
                $viewport.Height
            )


        $scrollRail.Height =
            [Math]::Max(
                24,
                ($viewport.Height - 8)
            )


        $maxScroll =
            [Math]::Max(
                0,
                ($content.Height - $viewport.Height)
            )


        $scrollState =
            [pscustomobject]@{
                Offset =
                    0

                Max =
                    $maxScroll

                Dragging =
                    $false

                StartY =
                    0

                StartOffset =
                    0
            }


                if($maxScroll -le 0){
            # SHINY-DECK-NO-SCROLL-GUTTER-V5
            $viewport.Width = $script:DeckWidth - 2
            $content.Width = $script:DeckWidth - 2
            foreach($cardShell in @($content.Controls)){
                $cardShell.Width = $script:DeckWidth - 2
                Set-RoundedRegion $cardShell $script:AlertVisual.CardRadius
                foreach($innerCard in @($cardShell.Controls)){
                    $innerCard.Width = $script:DeckWidth - 4
                    Set-RoundedRegion $innerCard ($script:AlertVisual.CardRadius - 1)
                }
            }

            $scrollRail.Visible =
                $false

            $script:ActiveDeckScrollHandler =
                $null
        }
        else {

            $scrollRail.Visible =
                $true


            $thumbHeight =
                [Math]::Max(
                    36,
                    [int][Math]::Round(
                        $scrollRail.Height *
                        (
                            $viewport.Height /
                            [double]$content.Height
                        )
                    )
                )


            $thumbHeight =
                [Math]::Min(
                    $scrollRail.Height,
                    $thumbHeight
                )


            $scrollThumb.Height =
                $thumbHeight


            Set-RoundedRegion `
                $scrollRail `
                3


            Set-RoundedRegion `
                $scrollThumb `
                3


            $applyScroll = {

                param(
                    [int]$RequestedOffset
                )


                $offset =
                    [Math]::Min(
                        $scrollState.Max,
                        [Math]::Max(
                            0,
                            $RequestedOffset
                        )
                    )


                $scrollState.Offset =
                    $offset


                $script:DeckScrollOffset =
                    $offset


                $content.Top =
                    -$offset


                $travel =
                    [Math]::Max(
                        0,
                        (
                            $scrollRail.Height -
                            $scrollThumb.Height
                        )
                    )


                $thumbTop =
                    if(
                        $scrollState.Max -gt 0 -and
                        $travel -gt 0
                    ){
                        [int][Math]::Round(
                            $travel *
                            (
                                $offset /
                                [double]$scrollState.Max
                            )
                        )
                    }
                    else {
                        0
                    }


                $scrollThumb.Top =
                    $thumbTop

            }.GetNewClosure()


            $scrollWheel = {

                param(
                    [int]$Delta
                )


                $steps =
                    [Math]::Max(
                        1,
                        [int](
                            [Math]::Abs($Delta) /
                            120
                        )
                    )


                $amount =
                    56 *
                    $steps


                if($Delta -gt 0){
                    $amount = -$amount
                }


                & $applyScroll (
                    $scrollState.Offset +
                    $amount
                )

            }.GetNewClosure()


            $script:ActiveDeckScrollHandler =
                $scrollWheel


            $scrollRail.Add_MouseDown({

                param(
                    $sender,
                    $eventArgs
                )


                if(
                    $eventArgs.Button -ne
                    [System.Windows.Forms.MouseButtons]::Left
                ){
                    return
                }


                $travel =
                    [Math]::Max(
                        1,
                        (
                            $scrollRail.Height -
                            $scrollThumb.Height
                        )
                    )


                $targetThumbTop =
                    [Math]::Min(
                        $travel,
                        [Math]::Max(
                            0,
                            (
                                $eventArgs.Y -
                                [int]($scrollThumb.Height / 2)
                            )
                        )
                    )


                $targetOffset =
                    [int][Math]::Round(
                        $scrollState.Max *
                        (
                            $targetThumbTop /
                            [double]$travel
                        )
                    )


                & $applyScroll `
                    $targetOffset

            }.GetNewClosure())


            $scrollThumb.Add_MouseDown({

                param(
                    $sender,
                    $eventArgs
                )


                if(
                    $eventArgs.Button -eq
                    [System.Windows.Forms.MouseButtons]::Left
                ){
                    $scrollState.Dragging =
                        $true

                    $scrollState.StartY =
                        [System.Windows.Forms.Cursor]::Position.Y

                    $scrollState.StartOffset =
                        $scrollState.Offset
                }

            }.GetNewClosure())


            $scrollThumb.Add_MouseMove({

                param(
                    $sender,
                    $eventArgs
                )


                if(!$scrollState.Dragging){
                    return
                }


                $deltaY =
                    [System.Windows.Forms.Cursor]::Position.Y -
                    $scrollState.StartY


                $travel =
                    [Math]::Max(
                        1,
                        (
                            $scrollRail.Height -
                            $scrollThumb.Height
                        )
                    )


                $offsetDelta =
                    [int][Math]::Round(
                        $scrollState.Max *
                        (
                            $deltaY /
                            [double]$travel
                        )
                    )


                & $applyScroll (
                    $scrollState.StartOffset +
                    $offsetDelta
                )

            }.GetNewClosure())


            $scrollThumb.Add_MouseUp({

                $scrollState.Dragging =
                    $false

            }.GetNewClosure())


            $scrollThumb.Add_MouseLeave({

                if(
                    [System.Windows.Forms.Control]::MouseButtons -eq
                    [System.Windows.Forms.MouseButtons]::None
                ){
                    $scrollState.Dragging =
                        $false
                }

            }.GetNewClosure())


            & $applyScroll 0
        }        # Match the header anchor across upward/downward expansion and new alerts.
        if($script:ExpansionDirection -eq 'up'){
            $header.Top = $form.Height - 40
            $viewport.Top = 0
            $scrollRail.Top = 4
        }else{
            $header.Top = 0
            $viewport.Top = 46
            $scrollRail.Top = 50
        }
        if($script:DeckPositionInitialized){
            $form.Top = if($script:ExpansionDirection -eq 'up'){
                $anchorY - ($form.Height - 40)
            }else{ $anchorY }
        }
        $script:LastLayoutDirection = $script:ExpansionDirection
        Set-DeckHoverDescriptor $dashboard 'Open the ShinySlack dashboard'
        Set-DeckHoverDescriptor $direction $(if($script:ExpansionDirection -eq 'up') {'Alerts expand upward. Click to switch downward.'} else {'Alerts expand downward. Click to switch upward.'})
        Set-DeckHoverDescriptor $minus 'Collapse the alert cards into the header'
        Set-DeckHoverDescriptor $closeAll 'Hide deck and keep alerts. Use Open Alert Deck to restore.'
        # Resize cursor appears at any corner.




        Position-Form
        Set-RoundedRegion $form 14
        Add-DeckCornerHandles
        Add-DeckInlineVolume -Left 0 -Top 0
        if($script:DeckVolumeWindow -and $script:DeckVolumeWindow.Visible){Position-DeckVolumeWindow}


        if(!$form.Visible){
            $form.Show()
        }
    }
    finally {
        $form.ResumeLayout($true)
    }
}

function Render {
    if($script:DeckHiddenAt){ return }
    if($script:Tucked){
        Render-Tucked
    }
    else {
        Render-Expanded
    }
}

# SHINY-DECK-TITLE-GLOW-CYCLE-V1
# Smoothly interpolate through the same palette used for alert accent rails.
# The title itself remains white; its subtle halo breathes in the active color.
$script:DeckGlowColor = $script:AlertVisual.DefaultAccent
$script:DeckGlowStarted = [datetime]::UtcNow
$script:DeckGlowTitle = $null
$script:DeckGlowTimer = New-Object System.Windows.Forms.Timer
$script:DeckGlowTimer.Interval = 90
$script:DeckGlowTimer.Add_Tick({
    try {
        $title=$script:DeckGlowTitle
        if($null -eq $title -or $title.IsDisposed -or !$form.Visible){return}
        $colors=@($script:Palette)
        if($colors.Count -lt 2){return}
        $elapsed=([datetime]::UtcNow-$script:DeckGlowStarted).TotalSeconds
        $phase=($elapsed / 2.8) % $colors.Count
        $index=[int][Math]::Floor($phase)
        $fraction=$phase-$index
        $t=$fraction*$fraction*(3-2*$fraction)
        $a=[Drawing.ColorTranslator]::FromHtml([string]$colors[$index])
        $b=[Drawing.ColorTranslator]::FromHtml([string]$colors[(($index+1)%$colors.Count)])
        $r=[int][Math]::Round($a.R+($b.R-$a.R)*$t)
        $g=[int][Math]::Round($a.G+($b.G-$a.G)*$t)
        $bval=[int][Math]::Round($a.B+($b.B-$a.B)*$t)
        $next=[Drawing.Color]::FromArgb($r,$g,$bval)
        $script:DeckGlowColor=$next
        # Bright, color-tinted text plus layered translucent halo.
        $pulse=0.35+0.15*[Math]::Sin($elapsed*1.6)
        $title.ForeColor=[Drawing.Color]::FromArgb(
            [int][Math]::Round(245*(1-$pulse)+$r*$pulse),
            [int][Math]::Round(247*(1-$pulse)+$g*$pulse),
            [int][Math]::Round(251*(1-$pulse)+$bval*$pulse)
        )
        $title.Invalidate()
    } catch { }
})
$script:DeckGlowTimer.Start()
function Add-Alert {
    param([string]$Line)

    if(
        $Line -notmatch
        '^(?<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) (?<kind>ROUTED|DEFAULT|STACK_EXTRA|STACK_EXTRA_DEFAULT) channel=(?<channel>\S+) sound=(?<sound>.+?) backend=(?<backend>\S+)(?:\s+.*)?$'
    ){
        return
    }

    try {
        $stamp = [datetime]::ParseExact(
            $Matches.stamp,
            'yyyy-MM-dd HH:mm:ss.fff',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        $stamp = Get-Date
    }

    $now = Get-Date

    $accentIndex =
        Get-NextAccentIndex `
            -Key $Line `
            -PreviousIndex $script:LastAccentIndex

    $script:LastAccentIndex =
        $accentIndex

    $obj = [pscustomobject]@{
        Id          = $script:NextId
        Time        = $stamp
        AddedAt     = $now
        Channel     = [string]$Matches.channel
        Sound       = [string]$Matches.sound
        EventKey    = $Line
        AccentIndex = [int]$accentIndex
        ExpireAt    = $now.AddSeconds($script:AutoDismissSeconds)
    }

    $script:NextId++

    [void]$script:Alerts.Add($obj)

    while($script:Alerts.Count -gt 30){
        $old = $script:Alerts |
            Sort-Object AddedAt |
            Select-Object -First 1

        [void]$script:Alerts.Remove($old)
    }

    # SHINY-DECK-THREE-WAY-GROWTH-V1
    # A new alert releases the temporary one-card reset, but not a lock.
    if($script:DeckGrowthMode -eq 'once'){
        if($script:NextId -gt $script:DeckGrowthArmedCount){
            $script:DeckGrowthMode = 'auto'
            $script:DeckHeight = 0
            $script:DeckScrollOffset = 0
            Save-DeckPosition
        }
    }elseif($script:DeckGrowthMode -eq 'auto' -and $script:DeckHeight -gt 0){
        # Resized custom height is temporary; grow naturally on the next alert.
        $script:DeckHeight = 0
        $script:DeckScrollOffset = 0
        Save-DeckPosition
    }

    Render
}

function Read-NewLines {
    if(!(Test-Path $log)){ return }

    try {
        $stream = New-Object IO.FileStream(
            $log,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )

        try {
            if($stream.Length -lt $script:Offset){
                $script:Offset = $stream.Length
                $script:Carry = ''
                return
            }

            if($stream.Length -eq $script:Offset){
                return
            }

            [void]$stream.Seek(
                $script:Offset,
                [IO.SeekOrigin]::Begin
            )

            $reader = New-Object IO.StreamReader(
                $stream,
                [Text.Encoding]::UTF8
            )

            try {
                $text = $reader.ReadToEnd()
                $script:Offset = $stream.Position
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }

        if(!$text){ return }

        $combined = $script:Carry + $text
        $parts = $combined -split "`r?`n"

        if($combined.EndsWith("`n")){
            $script:Carry = ''
            $complete = $parts
        }
        else {
            $script:Carry = $parts[-1]

            if($parts.Count -gt 1){
                $complete = $parts[0..($parts.Count - 2)]
            }
            else {
                $complete = @()
            }
        }

        foreach($line in @($complete)){
            if(![string]::IsNullOrWhiteSpace($line)){
                Add-Alert $line.Trim()
            }
        }
    }
    catch {
        # Overlay failure must never affect audio/router.
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250

$timer.Add_Tick({
    # SHINY-DECK-SHOW-REQUEST-275-V1
    # Explicit launch request: show the existing hidden form (or bring it forward).
    # Only the deck handles this request. Router/audio remain untouched.
    try {
        $showFile = Join-Path $root 'persistent-alerts-show.request'
        if (Test-Path -LiteralPath $showFile) {
            Remove-Item -LiteralPath $showFile -Force -ErrorAction SilentlyContinue
            if($script:DeckHiddenAt){
                $now = Get-Date
                foreach($a in @($script:Alerts)){
                    if(!$a.ExpireAt){continue}
                    $from = $script:DeckHiddenAt
                    if($a.AddedAt -and $a.AddedAt -gt $from){$from=$a.AddedAt}
                    $a.ExpireAt=$a.ExpireAt.Add($now-$from)
                }
                $script:DeckHiddenAt=$null
            }
            Hide-DeckHoverPopup
            if (-not $form.Visible) {
                # Closing the deck can invalidate the native tooltip window.
                # Reset it before controls are reconstructed by Render.
                Reset-DeckHoverHelp
                Render
            }
            if ($form.Visible) {
                $form.BringToFront()
                [void]$form.Activate()
            }
        }
    } catch {
        # Never let a presentation-only request interrupt notification polling.
    }

    Read-Settings
    if (Sync-NativeTheme) { Render }
    # SHINY-MUTE-FAILSAFE-279-V1
    # Visible deck pulse: Router may preserve intentional mute while visible.
    try {
        if($form.Visible -and !$script:DeckHiddenAt){
            if(!$script:LastVolumePresence -or ((Get-Date)-$script:LastVolumePresence).TotalSeconds -ge 5){
                [IO.File]::WriteAllText(
                    (Join-Path $root 'deck-visible.heartbeat'),
                    (Get-Date).ToString('o'),
                    (New-Object Text.UTF8Encoding($false))
                )
                $script:LastVolumePresence=Get-Date
            }
        }else{
            Remove-Item -LiteralPath (Join-Path $root 'deck-visible.heartbeat') -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    if(!$script:DeckVolumeDragging -and ((Get-Date)-$script:DeckVolumeReadAt).TotalMilliseconds -ge 1200){
        $script:DeckVolumeReadAt=Get-Date
        Read-DeckVolume
        Update-DeckVolumeVisual
    }
    Read-NewLines
    if($script:DeckHiddenAt){ return }
    # Tucked = countdown frozen.
    if($script:Tucked){ return }
    if(!$script:AutoDismiss){ return }

    $now = Get-Date

    $expired = @(
        $script:Alerts |
        Where-Object {
            $_.ExpireAt -and
            $_.ExpireAt -le $now
        }
    )

    if($expired.Count){
        foreach($a in $expired){
            [void]$script:Alerts.Remove($a)
        }

        Render-Expanded
    }
})

$timer.Start()

# Message loop stays alive even while no alert is visible.
[System.Windows.Forms.Application]::Run()