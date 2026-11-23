# ShinySlack v2.7.11 packaged-source contract. Run by Windows Actions before installer.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
function Require-Text([string]$file,[string]$needle,[string]$label) {
    $path=Join-Path $repo $file
    if(!(Test-Path -LiteralPath $path)){throw "RELEASE CONTRACT: Missing $file"}
    $txt=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    if(!$txt.Contains($needle)){throw "RELEASE CONTRACT: Missing $label in $file"}
}
$deck=Join-Path $repo 'app/PersistentAlerts.ps1'
$strictUtf8=[System.Text.UTF8Encoding]::new($false,$true)
$deckText=$strictUtf8.GetString([IO.File]::ReadAllBytes($deck))
foreach($needle in @('SHINY-DECK-ICONS-CORNERS-DOUBLECLICK-V1',
                    'SHINY-DECK-VOLUME-SAVE-V2',
                    'SHINY-DECK-COMPACT-VOLUME-279-V1',
                    'SHINY-DECK-SPARKLE-279-V1',
                    'SHINY-DECK-TITLE-GLOW-CYCLE-V1',
                    'deck-visible.heartbeat',
                    'Toggle-DeckVolumeWindow',
                    'Set-DeckIcon')) {
    if(!$deckText.Contains($needle)){throw "RELEASE CONTRACT: Deck missing $needle"}
}
if(([regex]::Matches($deckText,'\[string\]\[char\]0x2728')).Count -ne 2) {
    throw 'RELEASE CONTRACT: Both headers must render U+2728 sparkle'
}
if($deckText -match '(?i)(?:New-Object\s+(?:-TypeName\s+)?(?:System\.Windows\.Forms\.)?ContextMenuStrip\b|\[(?:System\.)?Windows\.Forms\.ContextMenuStrip\]::new\s*\()') {
    throw 'RELEASE CONTRACT: Rejected crashing context-menu popup implementation'
}
if(!($deckText.Contains("`$grip.Text") -and $deckText.Contains("`$dragGrip.Text"))) {
    throw 'RELEASE CONTRACT: Existing drag grips must remain'
}
Require-Text 'app/ChannelRouter.ps1' 'SHINY-MUTE-FAILSAFE-279-V1' 'router auto-unmute guard'
Require-Text 'app/ShinySlack-Web.ps1' 'dashboard-visible.heartbeat' 'dashboard visibility tracking'
Require-Text 'app/index.html' 'SHINY-MUTE-FAILSAFE-279-V1' 'dashboard mute warning'
Require-Text 'app/index.html' 'id="testSlackbot"' 'Slackbot test UI'
Require-Text 'docs/index.html' 'v2.7.11 - HTML Deck V10.4' 'updated landing release copy'
Require-Text 'docs/index.html' 'What happens if I mute ShinySlack' 'public mute behavior documentation'
Require-Text 'README.md' 'Current Windows release: v2.7.11.' 'README release version'
Require-Text 'docs/FAQ.md' 'What if I leave ShinySlack muted?' 'full FAQ volume safety documentation'
Require-Text 'installer/ShinySlack.iss' 'Source: "..\app\*"' 'installer bundles all app files'
Require-Text 'app/version.txt' 'v2.7.11' 'app release version'
$tok=$null;$err=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($deck,[ref]$tok,[ref]$err)
if(@($err | Where-Object {$null -ne $_}).Count -gt 0){throw 'RELEASE CONTRACT: Deck PowerShell parser failed'}
Write-Host 'SHINYSLACK v2.7.11 RELEASE CONTRACT: PASS' -ForegroundColor Green
# HTML production runtime, shipped inside the Inno Setup app payload.
foreach($relative in @(
 'app/HtmlDeck/host/app/ShinySlack.HtmlDeck.Host.exe',
 'app/HtmlDeck/host/app/deck-live.html',
 'app/HtmlDeck/host/app/deck-live.js',
 'app/HtmlDeck/host/Program.cs',
 'app/HtmlDeck/deck-live.html',
 'app/HtmlDeck/deck-live.js',
 'app/HtmlDeck/promotion-v10-stage.json',
 'app/HtmlDeck/production-enabled.flag',
 'app/HtmlDeck/Start-HTMLDeck-Prod-v10.ps1',
 'app/HtmlDeck/Open-HTMLDeck-Prod-v10.ps1',
 'app/HtmlDeck/Launch-HTMLDeck-Owner.ps1'
)) {
  if(!(Test-Path -LiteralPath (Join-Path $repo $relative) -PathType Leaf)) {
    throw "RELEASE CONTRACT: missing HTML payload $relative"
  }
}
$bridge=[IO.File]::ReadAllText((Join-Path $repo 'app/HtmlDeck/Open-HTMLDeck-Prod-v10.ps1'))
if($bridge -match '\$legacyRouteFlag\s+-PathType\s+Leaf') {throw 'RELEASE CONTRACT: HTML production startup still requires development route flag.'}
$launch=[IO.File]::ReadAllText((Join-Path $repo 'app/Start-ShinySlack.ps1'))
if(!$launch.Contains('Launch-HTMLDeck-Owner.ps1')){throw 'RELEASE CONTRACT: main launcher does not target HTML production bridge.'}
Write-Host 'HTML production payload and startup: PASS' -ForegroundColor Green