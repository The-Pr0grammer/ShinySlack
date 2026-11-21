$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot

$psExe = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'


function Test-ShinyProcess {
    param(
        [string]$ScriptName,
        [string]$FullPath
    )

    try {

        $found = @(
            Get-CimInstance `
                Win32_Process `
                -Filter "Name='powershell.exe'" `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match
                    [regex]::Escape($ScriptName) -and
                $_.CommandLine.IndexOf(
                    $FullPath,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            }
        )

        return ($found.Count -gt 0)
    }
    catch {
        return $false
    }
}


# ============================================================
# ROUTER
# ============================================================

$router =
    Join-Path $root 'ChannelRouter.ps1'

$routerLauncher =
    Join-Path $root 'Start-ChannelRouter.ps1'

if(
    (Test-Path $routerLauncher) -and
    -not (
        Test-ShinyProcess `
            -ScriptName 'ChannelRouter.ps1' `
            -FullPath $router
    )
) {
    Start-Process `
        -FilePath $psExe `
        -ArgumentList (
            '-NoProfile -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass ' +
            '-File "' + $routerLauncher + '"'
        ) `
        -WindowStyle Hidden |
        Out-Null
}


# ============================================================
# CACHE WATCHER
# ============================================================

$watcher =
    Join-Path $root 'Watch-ShinySlack.ps1'

$config =
    Join-Path $root 'config.json'

if(
    (Test-Path $watcher) -and
    (Test-Path $config) -and
    -not (
        Test-ShinyProcess `
            -ScriptName 'Watch-ShinySlack.ps1' `
            -FullPath $watcher
    )
) {
    Start-Process `
        -FilePath $psExe `
        -ArgumentList (
            '-NoProfile -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass ' +
            '-File "' + $watcher + '"'
        ) `
        -WindowStyle Hidden |
        Out-Null
}

exit 0
