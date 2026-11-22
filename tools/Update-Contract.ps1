# ShinySlack release gate: an existing installation must always offer a safe upgrade path.
# Runs before the installer is built. No network calls and no runtime changes.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
function Require-Text {
    param([string]$File,[string]$Needle,[string]$Reason)
    if(!(Test-Path -LiteralPath $File)){throw "UPDATE CONTRACT FAIL: Missing $File"}
    $text=[IO.File]::ReadAllText($File)
    if(!$text.Contains($Needle)){throw "UPDATE CONTRACT FAIL: $Reason ($File)"}
}
$web=Join-Path $repo 'app/ShinySlack-Web.ps1'
$ui=Join-Path $repo 'app/index.html'
$installer=Join-Path $repo 'installer/ShinySlack.iss'
$policy=Join-Path $repo 'UPDATE_POLICY.md'

# The existing local dashboard must be able to discover a *published release with installer*.
Require-Text $web "'/api/update/check'" 'Authenticated local update endpoint must exist'
Require-Text $web 'Convert-ShinyVersion' 'Semver-aware update comparison must exist'
Require-Text $web "-not [bool]`$item.draft -and" 'Must skip drafts and releases without an installer'
Require-Text $web "`$_.name -eq 'ShinySlackSetup.exe'" 'Must filter for the real installer asset'
Require-Text $web 'updateAvailable = $updateAvailable' 'Must expose update availability'
Require-Text $web 'installerUrl    = ' 'Must expose direct installer URL'
Require-Text $web 'checksumUrl     = ' 'Must expose checksum URL'
Require-Text $web 'releaseUrl      = ' 'Must expose official release notes/fallback URL'

# The UI must guide users through a transparent, user-initiated installer upgrade.
Require-Text $ui 'SHINY-UPDATE-DIRECT-INSTALLER-UX-V1' 'Direct installer update UI must exist'
Require-Text $ui "api('/api/update/check')" 'Update button must check release metadata'
Require-Text $ui 'updateInstallerUrl' 'Update button must track direct installer URL'
Require-Text $ui 'window.open(updateInstallerUrl' 'Update button must open the installer asset'
Require-Text $ui "'SHA-256 checksum'" 'Checksum must be accessible'
Require-Text $ui "'Release notes'" 'Official release page must remain accessible'
Require-Text $ui 'do not uninstall first' 'In-place upgrade guidance must be visible'
Require-Text $ui 'Reopen ShinySlack and check the version badge' 'Post-upgrade verification must be visible'
Require-Text $ui "if(updateReleaseUrl){window.open(updateReleaseUrl" 'Existing release URL fallback must be retained'
Require-Text $ui "addShinyReleaseLink(statusEl,'Open GitHub Releases'" 'Offline/error path must include official Releases fallback'
Require-Text $ui "'Up to date - '" 'Already-current users must get an accurate status'

# An upgrade must retain the same application identity/location and not require a pre-uninstall.
Require-Text $installer 'AppId={{6D65B1E8-3DF2-4A54-9A6E-7EDB4A63A2F1}' 'Stable installer application identity required for in-place upgrades'
Require-Text $installer 'DefaultDirName={localappdata}\ShinySlack' 'Existing per-user install location must be retained'
Require-Text $installer 'Flags: ignoreversion recursesubdirs createallsubdirs' 'Application files must upgrade in place'
Require-Text $policy 'Never auto-execute an installer' 'No unattended installation policy required'
Require-Text $policy 'Preserve existing user settings' 'Preservation policy required'
Require-Text $policy 'Fallback if GitHub is unavailable' 'Fallback path policy required'

Write-Host 'SHINYSLACK UPDATE CONTRACT: PASS' -ForegroundColor Green
Write-Host ' - New public builds must expose direct installer and checksum URLs'
Write-Host ' - Users receive instructions, manual installation, and a release-page fallback'
Write-Host ' - Existing install identity and location preserved'
Write-Host ' - Source checks are not a substitute for clean-Windows upgrade smoke tests'