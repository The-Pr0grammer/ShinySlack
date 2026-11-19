param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Mp3Path
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ShinySlack.Common.ps1')
$root = Get-ShinySlackRoot
$src = (Resolve-Path $Mp3Path).Path
Copy-Item $src (Join-Path $root 'custom.mp3') -Force
Remove-Item (Join-Path $root 'custom_prepared.mp3') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root 'state.json') -Force -ErrorAction SilentlyContinue
Write-ShinyLog "Custom MP3 changed to $src"
Invoke-ShinyRepair -RestartSlack $true | Out-Null
Write-Host 'Custom Slack sound updated. Test with a REAL notification.'
