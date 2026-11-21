$ErrorActionPreference = 'Stop'

$root =
    Join-Path `
        $env:LOCALAPPDATA `
        'ShinySlack'

$router =
    Join-Path `
        $root `
        'ChannelRouter.ps1'

$pidFile =
    Join-Path `
        $root `
        'channel-router.pid.json'


if(!(Test-Path -LiteralPath $router)) {
    exit 0
}


# ------------------------------------------------------------
# Existing router check without WMI/CIM
# ------------------------------------------------------------

if(Test-Path -LiteralPath $pidFile) {

    try {

        $info =
            Get-Content `
                -LiteralPath $pidFile `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json


        $proc =
            Get-Process `
                -Id ([int]$info.pid) `
                -ErrorAction Stop


        $recordedStart =
            [datetime]::Parse(
                [string]$info.started
            )


        $delta =
            [Math]::Abs(
                (
                    $proc.StartTime -
                    $recordedStart
                ).TotalSeconds
            )


        if(
            $proc.ProcessName -eq 'powershell' -and
            $delta -le 3
        ) {
            exit 0
        }
    }
    catch {}


    Remove-Item `
        -LiteralPath $pidFile `
        -Force `
        -ErrorAction SilentlyContinue
}


$ps =
    Join-Path `
        $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'

$stdout =
    Join-Path `
        $root `
        'channel-router.stdout.log'

$stderr =
    Join-Path `
        $root `
        'channel-router.stderr.log'

$args =
    "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$router`""


$proc =
    Start-Process `
        -FilePath $ps `
        -ArgumentList $args `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru


[pscustomobject]@{
    pid =
        $proc.Id

    started =
        $proc.StartTime.ToString('o')
} |
ConvertTo-Json -Compress |
Set-Content `
    -LiteralPath $pidFile `
    -Encoding UTF8