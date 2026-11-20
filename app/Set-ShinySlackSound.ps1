param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Mp3Path
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ShinySlack.Common.ps1')

$root = Get-ShinySlackRoot
$src = (Resolve-Path $Mp3Path).Path
$statePath = Join-Path $root 'state.json'

$previousState = $null

if(Test-Path -LiteralPath $statePath) {
    try {
        $previousState =
            Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {}
}

Copy-Item `
    -LiteralPath $src `
    -Destination (Join-Path $root 'custom.mp3') `
    -Force

Remove-Item `
    (Join-Path $root 'custom_prepared.mp3') `
    -Force `
    -ErrorAction SilentlyContinue

Write-ShinyLog "Custom MP3 changed to $src"

$fastSwapDone = $false

if(
    $previousState -and
    $previousState.File -and
    (Test-Path -LiteralPath ([string]$previousState.File))
) {
    try {
        $slot = [int]$previousState.SlotLength

        $oldRegion = Read-RegionBytes `
            -File ([string]$previousState.File) `
            -Offset ([long]$previousState.Offset) `
            -Length $slot

        if(
            $oldRegion -and
            (Get-Sha256Hex $oldRegion) -eq ([string]$previousState.CustomHash)
        ) {
            $wasRunning =
                [bool](Get-Process slack -ErrorAction SilentlyContinue)

            $slackExe = Get-SlackExePath
            $stoppedForPatch = $false

            try {
                if($wasRunning) {
                    Stop-SlackForPatch | Out-Null
                    $stoppedForPatch = $true
                    Start-Sleep -Milliseconds 800
                }

                $oldRegion = Read-RegionBytes `
                    -File ([string]$previousState.File) `
                    -Offset ([long]$previousState.Offset) `
                    -Length $slot

                if(
                    !$oldRegion -or
                    (Get-Sha256Hex $oldRegion) -ne ([string]$previousState.CustomHash)
                ) {
                    throw 'Saved cache region changed before sound swap.'
                }

                $prepared =
                    Ensure-CustomPrepared -SlotLength $slot

                $customBytes =
                    [IO.File]::ReadAllBytes($prepared)

                $padded =
                    New-PaddedCustomBytes `
                        -CustomBytes $customBytes `
                        -SlotLength $slot

                $customHash = Get-Sha256Hex $padded

                $backupDir = Join-Path $root 'backups'

                if(!(Test-Path $backupDir)) {
                    New-Item `
                        -ItemType Directory `
                        -Path $backupDir `
                        -Force |
                        Out-Null
                }

                $backup = Join-Path $backupDir (
                    "{0}_{1}.bak" -f `
                    ([IO.Path]::GetFileName([string]$previousState.File)),
                    (Get-Date -Format 'yyyyMMdd_HHmmss')
                )

                Copy-Item `
                    -LiteralPath ([string]$previousState.File) `
                    -Destination $backup `
                    -Force

                $fs = [IO.File]::Open(
                    [string]$previousState.File,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None
                )

                try {
                    $fs.Position = [long]$previousState.Offset
                    $fs.Write($padded,0,$padded.Length)
                    $fs.Flush()
                }
                finally {
                    $fs.Close()
                }

                $verify = Read-RegionBytes `
                    -File ([string]$previousState.File) `
                    -Offset ([long]$previousState.Offset) `
                    -Length $slot

                if(
                    !$verify -or
                    (Get-Sha256Hex $verify) -ne $customHash
                ) {
                    throw "Direct sound swap verification failed. Backup: $backup"
                }

                Save-ShinyState `
                    -File ([string]$previousState.File) `
                    -Offset ([long]$previousState.Offset) `
                    -SlotLength $slot `
                    -StockHash ([string]$previousState.StockHash) `
                    -CustomHash $customHash

                Write-ShinyLog `
                    "Direct custom sound swap verified at saved cache region."

                $fastSwapDone = $true
            }
            finally {
                if($stoppedForPatch) {
                    Start-SlackAfterPatch -ExePath $slackExe
                }
            }
        }
    }
    catch {
        Write-ShinyLog `
            "Saved-region sound swap unavailable: $($_.Exception.Message)"
    }
}

if($fastSwapDone) {
    Write-Host 'Custom Slack sound updated. Test with a REAL notification.'
    exit 0
}

Remove-Item `
    $statePath `
    -Force `
    -ErrorAction SilentlyContinue

$result = Invoke-ShinyRepair -RestartSlack $true

Write-Host "Custom Slack sound updated. Result: $result"
Write-Host 'Test with a REAL notification.'
