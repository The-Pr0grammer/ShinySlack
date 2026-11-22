param(
    [string]$RepoName = 'ShinySlack',
    [string]$Version = 'v2.7.6'
)
$ErrorActionPreference='Stop'

function Need($name,$installHint){
    if(!(Get-Command $name -ErrorAction SilentlyContinue)){
        throw "$name is required. $installHint"
    }
}

Need git 'Install Git for Windows first.'
Need gh 'Install GitHub CLI with: winget install --id GitHub.cli -e'

& gh auth status | Out-Host
if($LASTEXITCODE -ne 0){ throw 'GitHub CLI is not authenticated. Run: gh auth login' }

$root=$PSScriptRoot
Set-Location $root
$owner=(& gh api user --jq .login).Trim()
if(!$owner){ throw 'Could not determine GitHub username.' }
$full="$owner/$RepoName"

Write-Host "Publishing $full" -ForegroundColor Cyan

if(!(Test-Path '.git')){
    & git init
    & git branch -M main
}

& git add .
$changes=& git status --porcelain
if($changes){
    & git -c user.name="$owner" -c user.email="$owner@users.noreply.github.com" commit -m "ShinySlack beta distribution"
}

$repoExists=$false
& gh repo view $full *> $null
if($LASTEXITCODE -eq 0){$repoExists=$true}

if(!$repoExists){
    & gh repo create $full --public --source . --remote origin --push --description "Local-first Slack notification sounds, routing, alerts and Activity for Windows"
    if($LASTEXITCODE -ne 0){throw 'GitHub repository creation failed.'}
}else{
    $origin=& git remote get-url origin 2>$null
    if(!$origin){ & git remote add origin "https://github.com/$full.git" }
    & git push -u origin main
}

Write-Host 'Enabling GitHub Pages (GitHub Actions source)...' -ForegroundColor Cyan
& gh api --method POST "repos/$full/pages" -f build_type=workflow *> $null
# 409/422 can simply mean Pages already exists; the Pages workflow is authoritative.

if(& git tag --list $Version){
    Write-Host "Tag $Version already exists locally; not recreating it." -ForegroundColor Yellow
}else{
    & git tag $Version
}
& git push origin $Version
if($LASTEXITCODE -ne 0){throw "Failed to push $Version"}

Write-Host ''
Write-Host 'PUBLISHED.' -ForegroundColor Green
Write-Host "Repo: https://github.com/$full"
Write-Host "Actions: https://github.com/$full/actions"
Write-Host "Release (when build completes): https://github.com/$full/releases/latest"
Write-Host ("Site (when Pages deploy completes): https://{0}.github.io/{1}/" -f $owner, $RepoName)
Write-Host ''
Write-Host 'The website Download button will automatically point at ShinySlackSetup.exe from the latest GitHub Release.'
