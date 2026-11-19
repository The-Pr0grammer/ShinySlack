param(
    [bool]$RestartSlack = $true,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ShinySlack.Common.ps1')
try {
    $result = Invoke-ShinyRepair -RestartSlack $RestartSlack -Quiet:$Quiet
    if (!$Quiet) { Write-Host "Result: $result" }
    exit 0
} catch {
    Write-ShinyLog "Repair error: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}
