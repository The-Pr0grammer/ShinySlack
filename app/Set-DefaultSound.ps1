$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$root = Join-Path $env:LOCALAPPDATA "ShinySlack"
$configPath = Join-Path $root "channel-routes.json"
$soundDir = Join-Path $root "channel-sounds"

New-Item -ItemType Directory -Path $root -Force | Out-Null
New-Item -ItemType Directory -Path $soundDir -Force | Out-Null

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Choose ShinySlack DEFAULT notification sound"
$dialog.Filter = "MP3 audio (*.mp3)|*.mp3"

if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    exit
}

$destination = Join-Path $soundDir ("DEFAULT__" + [IO.Path]::GetFileName($dialog.FileName))

Copy-Item $dialog.FileName $destination -Force

$routes = @{}
$enabled = $true
$volume = 1.0

if(Test-Path $configPath) {

    $old = Get-Content $configPath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    if($null -ne $old.enabled) {
        $enabled = [bool]$old.enabled
    }

    if($null -ne $old.volume) {
        $volume = [double]$old.volume
    }

    if($null -ne $old.routes) {

        foreach($p in $old.routes.PSObject.Properties) {
            $routes[[string]$p.Name] = [string]$p.Value
        }
    }
}

[ordered]@{
    version = 2
    enabled = $enabled
    volume = $volume
    defaultSound = $destination
    routes = $routes
} |
ConvertTo-Json -Depth 6 |
Set-Content $configPath -Encoding UTF8

Write-Host ""
Write-Host "DEFAULT SOUND SAVED" -ForegroundColor Green
Write-Host $destination -ForegroundColor White
