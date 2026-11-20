$ErrorActionPreference = 'Stop'

$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
$router = Join-Path $root 'ChannelRouter.ps1'

if(!(Test-Path -LiteralPath $router)) {
    exit 0
}

$alreadyRunning = @(
    Get-CimInstance Win32_Process `
        -Filter "Name='powershell.exe'" `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf(
            $router,
            [StringComparison]::OrdinalIgnoreCase
        ) -ge 0 -and
        $_.CommandLine.IndexOf(
            'Start-ChannelRouter.ps1',
            [StringComparison]::OrdinalIgnoreCase
        ) -lt 0
    }
)

if($alreadyRunning.Count -gt 0) {
    exit 0
}

$ps = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$stdout = Join-Path $root 'channel-router.stdout.log'
$stderr = Join-Path $root 'channel-router.stderr.log'

$args = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$router`""

Start-Process `
    -FilePath $ps `
    -ArgumentList $args `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr |
    Out-Null
