param(
    [string]$Channel
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$root = Join-Path $env:LOCALAPPDATA "ShinySlack"
$configPath = Join-Path $root "channel-routes.json"
$soundDir = Join-Path $root "channel-sounds"

New-Item -ItemType Directory -Path $root -Force | Out-Null
New-Item -ItemType Directory -Path $soundDir -Force | Out-Null

if([string]::IsNullOrWhiteSpace($Channel)) {
    $Channel = Read-Host "Slack channel name"
}

$Channel = $Channel.Trim()

if($Channel.StartsWith("#")) {
    $Channel = $Channel.Substring(1)
}

if([string]::IsNullOrWhiteSpace($Channel)) {
    throw "Channel cannot be empty."
}

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Choose MP3 for #$Channel"
$dialog.Filter = "MP3 audio (*.mp3)|*.mp3"
$dialog.Multiselect = $false

$result = $dialog.ShowDialog()

if($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "No sound selected." -ForegroundColor Yellow
    exit 0
}

$source = $dialog.FileName

$safeChannel = $Channel -replace '[^A-Za-z0-9._-]', '_'
$fileName = [IO.Path]::GetFileName($source)

$destination =
    Join-Path $soundDir ("{0}__{1}" -f $safeChannel,$fileName)

Copy-Item `
    -LiteralPath $source `
    -Destination $destination `
    -Force

$routes = @{}
$enabled = $true
$volume = 1.0
$defaultSound = $null

if(Test-Path $configPath) {

    try {

        $old = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
            ConvertFrom-Json

        if($null -ne $old.enabled) {
            $enabled = [bool]$old.enabled
        }

        if($null -ne $old.volume) {
            $volume = [double]$old.volume
        }

        if($null -ne $old.defaultSound) {
            $defaultSound = [string]$old.defaultSound
        }

        if($null -ne $old.routes) {

            foreach($property in $old.routes.PSObject.Properties) {

                $routes[[string]$property.Name] =
                    [string]$property.Value
            }
        }
    }
    catch {
        Write-Host "Existing config could not be read. Rebuilding it." -ForegroundColor Yellow
    }
}

$routes[$Channel] = $destination

$config = [ordered]@{
    version = 1
    enabled = $enabled
    volume = $volume
    defaultSound = $defaultSound
    routes = $routes
}

$config |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $configPath -Encoding UTF8

Write-Host ""
Write-Host "CHANNEL ROUTE SAVED" -ForegroundColor Green
Write-Host "#$Channel" -ForegroundColor Cyan
Write-Host "-> $destination" -ForegroundColor White
Write-Host ""
Write-Host "Config:" -ForegroundColor DarkGray
Write-Host $configPath -ForegroundColor DarkGray

