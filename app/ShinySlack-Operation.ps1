param([Parameter(Mandatory=$true)][string]$RequestFile)
$ErrorActionPreference='Stop'

function Write-State {
    param([string]$Status,[int]$ExitCode=-1,[string]$ErrorMessage='')
    $req = Get-Content $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $statePath = [string]$req.StatePath
    [pscustomobject]@{
        status=$Status
        exitCode=$ExitCode
        error=$ErrorMessage
        updated=(Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content $statePath -Encoding UTF8
}

$req = Get-Content $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
$logPath = [string]$req.LogPath
$cleanup = [string]$req.CleanupPath
try {
    Write-State 'running'
    "[$(Get-Date -Format 'HH:mm:ss')] Starting ShinySlack operation..." | Set-Content $logPath -Encoding UTF8
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',[string]$req.Script)
    foreach($a in @($req.Arguments)) { $args += [string]$a }
    & $ps @args 2>&1 | ForEach-Object {
        $_.ToString() | Add-Content $logPath -Encoding UTF8
    }
    $code = $LASTEXITCODE
    if($code -eq 0){
        Write-State 'done' 0
    } else {
        Write-State 'error' $code "Operation exited with code $code."
    }
} catch {
    try { $_.Exception.ToString() | Add-Content $logPath -Encoding UTF8 } catch {}
    Write-State 'error' 1 $_.Exception.Message
} finally {
    if($cleanup){ Remove-Item $cleanup -Force -ErrorAction SilentlyContinue }
}
