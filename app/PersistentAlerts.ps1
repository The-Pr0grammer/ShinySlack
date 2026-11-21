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

function Get-Accent {
    param([string]$Key)

    [uint64]$hash = 0

    foreach($ch in $Key.ToCharArray()){
        $hash = (($hash * 31) + [int][char]$ch) % 4294967296
    }

    $hex = $script:Palette[
        [int]($hash % $script:Palette.Count)
    ]

    [Drawing.ColorTranslator]::FromHtml($hex)
}

function New-Button {
    param(
        [string]$Text,
        [int]$Width = 28
    )

    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = $Width
    $b.Height = 25
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = [Drawing.Color]::FromArgb(36,39,47)
    $b.ForeColor = [Drawing.Color]::Gainsboro
    $b.Font = New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b
}

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = [Drawing.Color]::FromArgb(20,22,27)
$form.ForeColor = [Drawing.Color]::White
$form.Width = 390
$form.Height = 100
$form.Opacity = .985
$form.AutoScroll = $false
# SHINY-DECK-GLOBAL-WHEEL-V1
$form.Add_MouseWheel({
    param($sender,$eventArgs)

    if($script:ActiveDeckScrollHandler){
        & $script:ActiveDeckScrollHandler $eventArgs.Delta
    }
})


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


function Enable-DeckDrag {
    param($Control)

    if(!$Control){
        return
    }


    $Control.Cursor =
        [System.Windows.Forms.Cursors]::SizeAll


    $Control.Add_MouseDown({

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


        [void][ShinySlackDeckDragV1]::ReleaseCapture()


        [void][ShinySlackDeckDragV1]::SendMessage(
            $form.Handle,
            0x00A1,
            [IntPtr]2,
            [IntPtr]::Zero
        )


        Clamp-DeckPosition
        Save-DeckPosition
    })
}


function Render-Tucked {

    $form.SuspendLayout()

    try {

        $script:ActiveDeckScrollHandler =
            $null


        $form.Controls.Clear()
        $form.AutoScroll = $false

        $form.Width = 248
        $form.Height = 38


        $bar =
            New-Object System.Windows.Forms.Panel

        $bar.Dock =
            'Fill'

        $bar.BackColor =
            [Drawing.Color]::FromArgb(
                12,
                17,
                24
            )


        $accent =
            New-Object System.Windows.Forms.Panel

        $accent.Left = 0
        $accent.Top = 0
        $accent.Width = 3
        $accent.Height = 38

        $accent.BackColor =
            [Drawing.Color]::FromArgb(
                85,
                216,
                255
            )


        $grip =
            New-Object System.Windows.Forms.Label

        $grip.Left = 10
        $grip.Top = 10
        $grip.Width = 18
        $grip.Height = 16
        $grip.Text = '::'

        $grip.ForeColor =
            [Drawing.Color]::FromArgb(
                85,
                102,
                123
            )

        $grip.Font =
            New-Object Drawing.Font(
                'Consolas',
                9,
                [Drawing.FontStyle]::Bold
            )


        $title =
            New-Object System.Windows.Forms.Label

        $title.Left = 31
        $title.Top = 9
        $title.Width = 78
        $title.Height = 18
        $title.Text = 'ShinySlack'

        $title.ForeColor =
            [Drawing.Color]::FromArgb(
                233,
                240,
                248
            )

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

        $count.Left = 112
        $count.Top = 10
        $count.Width = 84
        $count.Height = 17
        $count.Text = $countText

        $count.ForeColor =
            [Drawing.Color]::FromArgb(
                111,
                129,
                151
            )

        $count.Font =
            New-Object Drawing.Font(
                'Segoe UI',
                8
            )


        $plus =
            New-Button '+' 28

        $plus.Left = 214
        $plus.Top = 6
        $plus.Height = 26

        $plus.BackColor =
            [Drawing.Color]::FromArgb(
                23,
                31,
                42
            )

        $plus.ForeColor =
            [Drawing.Color]::FromArgb(
                101,
                222,
                255
            )


        Set-RoundedRegion $plus 8


        $plus.Add_Click({

            $now =
                Get-Date


            foreach($a in @($script:Alerts)){

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


        $bar.Controls.Add($accent)
        $bar.Controls.Add($grip)
        $bar.Controls.Add($title)
        $bar.Controls.Add($count)
        $bar.Controls.Add($plus)

        $form.Controls.Add($bar)


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

function Render-Expanded {
    $form.SuspendLayout()

    try {
        $form.Controls.Clear()
        # SHINY-DECK-CUSTOM-SCROLL-V1
        $form.AutoScroll = $false
        $form.Width = 404

        $items = @(
            $script:Alerts |
            Sort-Object AddedAt -Descending
        )

        if($items.Count -eq 0){
            $form.Hide()
            return
        }


        # =====================================================
        # HEADER
        # =====================================================

        $header =
            New-Object System.Windows.Forms.Panel

        $header.Left = 0
        $header.Top = 0
        $header.Width = 404
        $header.Height = 32

        $header.BackColor =
            [Drawing.Color]::FromArgb(
                14,
                19,
                27
            )

        Set-RoundedRegion $header 10


        $dragGrip =
            New-Object System.Windows.Forms.Label

        $dragGrip.Left = 10
        $dragGrip.Top = 8
        $dragGrip.Width = 18
        $dragGrip.Height = 17
        $dragGrip.Text = '::'

        $dragGrip.ForeColor =
            [Drawing.Color]::FromArgb(
                79,
                98,
                122
            )

        $dragGrip.Font =
            New-Object Drawing.Font(
                'Consolas',
                9,
                [Drawing.FontStyle]::Bold
            )

        $title =
            New-Object System.Windows.Forms.Label

        $title.Left = 32
        $title.Top = 7
        $title.Width = 98
        $title.Height = 18
        $title.Text = 'ShinySlack'

        $title.ForeColor =
            [Drawing.Color]::FromArgb(
                226,
                232,
                240
            )

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

        $count.Left = 118
        $count.Top = 8
        $count.Width = 100
        $count.Height = 17
        $count.Text = $countText

        $count.ForeColor =
            [Drawing.Color]::FromArgb(
                115,
                131,
                151
            )

        $count.Font =
            New-Object Drawing.Font(
                'Segoe UI',
                8
            )


        # -----------------------------------------------------
        # GLOBAL MINUS = TUCK ALL
        # -----------------------------------------------------

        $minus =
            New-Button '-' 28

        $minus.Left = 337
        $minus.Top = 4
        $minus.Height = 24

        $minus.BackColor =
            [Drawing.Color]::FromArgb(
                24,
                31,
                42
            )

        $minus.ForeColor =
            [Drawing.Color]::FromArgb(
                184,
                196,
                211
            )

        Set-RoundedRegion $minus 8


        $minus.Add_Click({

            $script:Tucked = $true
            $script:TuckStarted = Get-Date

            Render-Tucked
        })


        # -----------------------------------------------------
        # GLOBAL X = DISMISS ALL
        # -----------------------------------------------------

        $closeAll =
            New-Button 'X' 28

        $closeAll.Left = 369
        $closeAll.Top = 4
        $closeAll.Height = 24

        $closeAll.BackColor =
            [Drawing.Color]::FromArgb(
                24,
                31,
                42
            )

        $closeAll.ForeColor =
            [Drawing.Color]::FromArgb(
                184,
                196,
                211
            )

        Set-RoundedRegion $closeAll 8


        $closeAll.Add_Click({

            try {
                $script:Alerts.Clear()
            }
            catch {
                while($script:Alerts.Count -gt 0){
                    $script:Alerts.RemoveAt(
                        $script:Alerts.Count - 1
                    )
                }
            }

            $script:Tucked = $false
            $form.Hide()
        })


        $header.Controls.Add($dragGrip)
        $header.Controls.Add($title)
        $header.Controls.Add($count)
        $header.Controls.Add($minus)
        $header.Controls.Add($closeAll)

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

        $form.Controls.Add($header)


        # =====================================================
        # CUSTOM CARD VIEWPORT + DARK SCROLLBAR
        # =====================================================

        $viewport =
            New-Object System.Windows.Forms.Panel

        $viewport.Left = 0
        $viewport.Top = 38
        $viewport.Width = 394
        $viewport.Height = 100

        $viewport.BackColor =
            [Drawing.Color]::FromArgb(
                20,
                22,
                27
            )

        $viewport.AutoScroll =
            $false


        $content =
            New-Object System.Windows.Forms.Panel

        $content.Left = 0
        $content.Top = 0
        $content.Width = 390
        $content.Height = 100

        $content.BackColor =
            [Drawing.Color]::FromArgb(
                20,
                22,
                27
            )


        $scrollRail =
            New-Object System.Windows.Forms.Panel

        $scrollRail.Left = 397
        $scrollRail.Top = 42
        $scrollRail.Width = 5
        $scrollRail.Height = 90

        $scrollRail.BackColor =
            [Drawing.Color]::FromArgb(
                23,
                31,
                42
            )

        $scrollRail.Cursor =
            [Windows.Forms.Cursors]::Hand


        $scrollThumb =
            New-Object System.Windows.Forms.Panel

        $scrollThumb.Left = 0
        $scrollThumb.Top = 0
        $scrollThumb.Width = 5
        $scrollThumb.Height = 36

        $scrollThumb.BackColor =
            [Drawing.Color]::FromArgb(
                74,
                111,
                131
            )

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


        foreach($a in $items){

            $accent =
                Get-Accent $a.EventKey


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
            $shell.Width = 390
            $shell.Height = 66

            $shell.BackColor =
                [Drawing.Color]::FromArgb(
                    31,
                    40,
                    53
                )

            $shell.Tag = $a.Channel
            $shell.Cursor =
                [Windows.Forms.Cursors]::Hand

            $shell.Add_Click($openSlack)

            Set-RoundedRegion $shell 14


            # -------------------------------------------------
            # CARD
            # -------------------------------------------------

            $card =
                New-Object System.Windows.Forms.Panel

            $card.Left = 1
            $card.Top = 1
            $card.Width = 388
            $card.Height = 64

            $card.BackColor =
                [Drawing.Color]::FromArgb(
                    8,
                    13,
                    20
                )

            $card.Tag = $a.Channel
            $card.Cursor =
                [Windows.Forms.Cursors]::Hand

            $card.Add_Click($openSlack)

            Set-RoundedRegion $card 13


            # -------------------------------------------------
            # ACCENT RAIL
            # -------------------------------------------------

            $rail =
                New-Object System.Windows.Forms.Panel

            $rail.Left = 0
            $rail.Top = 0
            $rail.Width = 4
            $rail.Height = 64

            $rail.BackColor = $accent
            $rail.Tag = $a.Channel

            $rail.Cursor =
                [Windows.Forms.Cursors]::Hand

            $rail.Add_Click($openSlack)
            # -------------------------------------------------
            # CHANNEL — PAINTED GLOW TEXT
            # -------------------------------------------------

            $channelText =
                [string]$a.Channel

            $channelAccent =
                $accent

            $paintChannel = {

                param($sender,$paintArgs)

                $g =
                    $paintArgs.Graphics

                $g.SmoothingMode =
                    [Drawing.Drawing2D.SmoothingMode]::AntiAlias

                $g.TextRenderingHint =
                    [Drawing.Text.TextRenderingHint]::AntiAlias


                # Slightly shrink unusually long channel names.
                $fontSize =
                    if($channelText.Length -gt 23){
                        10.5
                    }
                    elseif($channelText.Length -gt 18){
                        11
                    }
                    else {
                        12
                    }


                $font =
                    New-Object Drawing.Font(
                        'Segoe UI',
                        $fontSize,
                        [Drawing.FontStyle]::Bold
                    )


                $format =
                    New-Object Drawing.StringFormat

                $format.Alignment =
                    [Drawing.StringAlignment]::Near

                $format.LineAlignment =
                    [Drawing.StringAlignment]::Center

                $format.Trimming =
                    [Drawing.StringTrimming]::EllipsisCharacter

                $format.FormatFlags =
                    [Drawing.StringFormatFlags]::NoWrap


                # Space available before timestamp.
                $rect =
                    New-Object Drawing.RectangleF(
                        15,
                        0,
                        240,
                        64
                    )


                # Soft glow — intentionally restrained.
                $glow =
                    New-Object Drawing.SolidBrush(
                        [Drawing.Color]::FromArgb(
                            52,
                            $channelAccent.R,
                            $channelAccent.G,
                            $channelAccent.B
                        )
                    )


                $main =
                    New-Object Drawing.SolidBrush(
                        $channelAccent
                    )


                try {

                    # ~CSS text-shadow: 0 0 6px currentColor
                    foreach($offset in @(
                        @(-2,0),
                        @( 2,0),
                        @(0,-2),
                        @(0, 2),
                        @(-1,-1),
                        @( 1,-1),
                        @(-1, 1),
                        @( 1, 1)
                    )){

                        $glowRect =
                            New-Object Drawing.RectangleF(
                                ($rect.X + $offset[0]),
                                ($rect.Y + $offset[1]),
                                $rect.Width,
                                $rect.Height
                            )

                        $g.DrawString(
                            $channelText,
                            $font,
                            $glow,
                            $glowRect,
                            $format
                        )
                    }


                    # Crisp foreground text.
                    $g.DrawString(
                        $channelText,
                        $font,
                        $main,
                        $rect,
                        $format
                    )
                }
                finally {

                    $font.Dispose()
                    $format.Dispose()
                    $glow.Dispose()
                    $main.Dispose()
                }

            }.GetNewClosure()


            $card.Add_Paint(
                $paintChannel
            )



            # -------------------------------------------------
            # TIME
            # -------------------------------------------------

            $time =
                New-Object System.Windows.Forms.Label

            $time.Left = 264
            $time.Top = 22
            $time.Width = 74
            $time.Height = 20

            $time.TextAlign = 'MiddleRight'
            $time.Text = $a.Time.ToString('h:mm tt')
            $time.ForeColor = $accent

            $time.Font =
                New-Object Drawing.Font(
                    'Segoe UI',
                    8,
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

            $x.Left = 349
            $x.Top = 20
            $x.Height = 24
            $x.Tag = $a.Id

            $x.BackColor =
                [Drawing.Color]::FromArgb(
                    21,
                    28,
                    38
                )

            $x.ForeColor =
                [Drawing.Color]::FromArgb(
                    184,
                    196,
                    211
                )

            Set-RoundedRegion $x 8


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


            $card.Controls.Add($rail)
            $card.Controls.Add($time)
            $card.Controls.Add($x)

            $shell.Controls.Add($card)
            $content.Controls.Add($shell)


            $top += 72
        }
        $form.Height =
            [Math]::Min(
                ($top + 44),
                610
            )


        $form.Height =
            [Math]::Max(
                110,
                $form.Height
            )


        $viewport.Height =
            $form.Height - 42


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
        }


        Position-Form
        Set-RoundedRegion $form 14


        if(!$form.Visible){
            $form.Show()
        }
    }
    finally {
        $form.ResumeLayout($true)
    }
}

function Render {
    if($script:Tucked){
        Render-Tucked
    }
    else {
        Render-Expanded
    }
}

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

    $obj = [pscustomobject]@{
        Id       = $script:NextId
        Time     = $stamp
        AddedAt  = $now
        Channel  = [string]$Matches.channel
        Sound    = [string]$Matches.sound
        EventKey = $Line
        ExpireAt = $now.AddSeconds($script:AutoDismissSeconds)
    }

    $script:NextId++

    [void]$script:Alerts.Add($obj)

    while($script:Alerts.Count -gt 30){
        $old = $script:Alerts |
            Sort-Object AddedAt |
            Select-Object -First 1

        [void]$script:Alerts.Remove($old)
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
    Read-Settings
    Read-NewLines

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