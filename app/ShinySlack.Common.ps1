$ErrorActionPreference = 'Stop'

function Get-ShinySlackRoot {
    Join-Path $env:LOCALAPPDATA 'ShinySlack'
}

function Get-SlackCacheDir {
    Join-Path $env:APPDATA 'Slack\Cache\Cache_Data'
}

function Get-ShinyWatcherHeartbeat {
    $root = Get-ShinySlackRoot
    $path = Join-Path $root 'watcher.heartbeat.json'
    if (!(Test-Path $path)) { return $null }
    try {
        $hb = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $updated = [datetime]::Parse([string]$hb.updated)
        $age = ((Get-Date) - $updated).TotalSeconds
        [pscustomobject]@{ Fresh=($age -le 45); AgeSeconds=[math]::Round($age,1); Data=$hb }
    } catch { $null }
}

function Get-ShinyWatcherProcesses {
    $root = Get-ShinySlackRoot
    $watcherPath = Join-Path $root 'Watch-ShinySlack.ps1'
    try {
        @(
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match 'Watch-ShinySlack\.ps1' -and
                $_.CommandLine.IndexOf($watcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        )
    } catch { @() }
}

function Test-ShinyWatcherRunning {
    $hb = Get-ShinyWatcherHeartbeat
    if ($hb -and $hb.Fresh) { return $true }
    @((Get-ShinyWatcherProcesses)).Count -gt 0
}

function Get-ShinySlackConfig {
    $root = Get-ShinySlackRoot
    $path = Join-Path $root 'config.json'
    if (!(Test-Path $path)) { throw "Missing config: $path" }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Write-ShinyLog {
    param([string]$Message)
    $root = Get-ShinySlackRoot
    if (!(Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $log = Join-Path $root 'ShinySlack.log'
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $log -Value $line -Encoding UTF8

    # Heartbeat logging can run all shift, so keep the file bounded.
    try {
        $fi = Get-Item $log -ErrorAction Stop
        if ($fi.Length -gt 2MB) {
            $tail = @(Get-Content $log -Tail 2500 -Encoding UTF8)
            Set-Content -Path $log -Value $tail -Encoding UTF8
            Add-Content -Path $log -Value ("{0}  Log rotated after exceeding 2 MB." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
        }
    } catch {}
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')
    } finally {
        $sha.Dispose()
    }
}

function Get-ActiveCacheFiles {
    param([string]$CacheDir)
    if (!(Test-Path $CacheDir)) { return @() }
    @(Get-ChildItem $CacheDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(data_\d+|f_[0-9a-fA-F]+)$'
    })
}

function Find-KnockBrushUrl {
    param([string]$CacheDir)
    $enc = [Text.Encoding]::GetEncoding(28591)
    $hits = @()
    foreach ($f in (Get-ActiveCacheFiles $CacheDir)) {
        try {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            $s = $enc.GetString($b)
            $m = [regex]::Matches($s, 'https://a\.slack-edge\.com/[^\x00\s]*?knock_brush[^\x00\s]*?\.mp3', 'IgnoreCase')
            foreach ($x in $m) {
                $hits += [pscustomobject]@{ Url = $x.Value; LastWriteTime = $f.LastWriteTime }
            }
        } catch {
            Write-ShinyLog "URL scan skipped $($f.Name): $($_.Exception.Message)"
        }
    }
    if ($hits.Count -eq 0) { return $null }
    ($hits | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Url
}

function Download-StockReference {
    param([string]$Url, [string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fL --connect-timeout 10 --max-time 20 -sS $Url -o $Destination
        if ($LASTEXITCODE -ne 0) { throw "Stock sound download failed (curl exit $LASTEXITCODE)." }
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 20
    }
    if (!(Test-Path $Destination) -or (Get-Item $Destination).Length -lt 1000) {
        throw "Stock sound download failed or produced an invalid file."
    }
}

function Ensure-StockReference {
    param([switch]$ForceRefresh)
    $root = Get-ShinySlackRoot
    $cache = Get-SlackCacheDir
    $stock = Join-Path $root 'stock_knock_brush.mp3'
    $urlFile = Join-Path $root 'stock_url.txt'

    $url = Find-KnockBrushUrl $cache
    if (!$url) {
        if ((Test-Path $stock) -and !$ForceRefresh) { return $stock }
        throw "Could not discover the Knock Brush URL. In Slack, select Knock Brush, trigger one REAL incoming notification, then run repair again."
    }

    $oldUrl = if (Test-Path $urlFile) { (Get-Content $urlFile -Raw).Trim() } else { '' }
    if ($ForceRefresh -or !(Test-Path $stock) -or $url -ne $oldUrl) {
        Write-ShinyLog "Refreshing stock reference from $url"
        Download-StockReference -Url $url -Destination $stock
        Set-Content -Path $urlFile -Value $url -Encoding ASCII
    }
    $stock
}

function Ensure-CustomPrepared {
    param([int]$SlotLength)
    $root = Get-ShinySlackRoot
    $custom = Join-Path $root 'custom.mp3'
    $prepared = Join-Path $root 'custom_prepared.mp3'
    if (!(Test-Path $custom)) { throw "Missing custom.mp3 in $root" }

    if ((Get-Item $custom).Length -le $SlotLength) {
        Copy-Item $custom $prepared -Force
        return $prepared
    }

    $ff = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if (!$ff) { $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue }
    if (!$ff) {
        throw "Custom MP3 is larger than the Slack slot and ffmpeg is not installed. Install it with: winget install --id Gyan.FFmpeg -e"
    }

    foreach ($rate in @(64,56,48,40,32)) {
        & $ff.Source -loglevel error -y -i $custom -ac 1 -ar 44100 -b:a ("{0}k" -f $rate) $prepared
        if ($LASTEXITCODE -eq 0 -and (Test-Path $prepared) -and (Get-Item $prepared).Length -le $SlotLength) {
            Write-ShinyLog "Prepared custom sound at ${rate}k: $((Get-Item $prepared).Length) bytes"
            return $prepared
        }
    }
    throw "Could not compress the custom MP3 below the Slack slot size ($SlotLength bytes)."
}

function New-PaddedCustomBytes {
    param([byte[]]$CustomBytes, [int]$SlotLength)
    if ($CustomBytes.Length -gt $SlotLength) { throw "Custom sound is too large." }
    $padded = New-Object byte[] $SlotLength
    [Array]::Copy($CustomBytes, 0, $padded, 0, $CustomBytes.Length)
    return ,$padded
}

function Find-ExactRegion {
    param([byte[]]$Needle, [string]$CacheDir)
    if ($Needle.Length -lt 64) { throw "Reference is too small." }
    $enc = [Text.Encoding]::GetEncoding(28591)
    $first = $enc.GetString([byte[]]$Needle[0..63])
    $wanted = Get-Sha256Hex $Needle

    foreach ($f in (Get-ActiveCacheFiles $CacheDir)) {
        try {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -lt $Needle.Length) { continue }
            $hay = $enc.GetString($bytes)
            $pos = 0
            while (($pos = $hay.IndexOf($first, $pos, [StringComparison]::Ordinal)) -ge 0) {
                if (($pos + $Needle.Length) -le $bytes.Length) {
                    $candidate = New-Object byte[] $Needle.Length
                    [Array]::Copy($bytes, $pos, $candidate, 0, $Needle.Length)
                    if ((Get-Sha256Hex $candidate) -eq $wanted) {
                        return [pscustomobject]@{ File = $f.FullName; Offset = $pos }
                    }
                }
                $pos++
            }
        } catch {
            Write-ShinyLog "Exact scan skipped $($f.Name): $($_.Exception.Message)"
        }
    }
    $null
}

function Read-RegionBytes {
    param([string]$File, [long]$Offset, [int]$Length)
    if (!(Test-Path $File)) { return $null }
    $buf = New-Object byte[] $Length
    $fs = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if (($Offset + $Length) -gt $fs.Length) { return $null }
        $fs.Position = $Offset
        $read = $fs.Read($buf, 0, $buf.Length)
        if ($read -ne $Length) { return $null }
        return ,$buf
    } finally {
        $fs.Close()
    }
}

function Save-ShinyState {
    param([string]$File,[long]$Offset,[int]$SlotLength,[string]$StockHash,[string]$CustomHash)
    $root = Get-ShinySlackRoot
    [pscustomobject]@{
        File = $File
        Offset = $Offset
        SlotLength = $SlotLength
        StockHash = $StockHash
        CustomHash = $CustomHash
        Updated = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content (Join-Path $root 'state.json') -Encoding UTF8
}

function Get-ShinyStateHealth {
    $root = Get-ShinySlackRoot
    $stateFile = Join-Path $root 'state.json'
    if (!(Test-Path $stateFile)) { return 'Unknown' }
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        $bytes = Read-RegionBytes -File $state.File -Offset ([long]$state.Offset) -Length ([int]$state.SlotLength)
        if ($null -eq $bytes) { return 'Unknown' }
        $h = Get-Sha256Hex $bytes
        if ($h -eq $state.CustomHash) { return 'Custom' }
        if ($h -eq $state.StockHash) { return 'Stock' }
        return 'Unknown'
    } catch {
        return 'Unknown'
    }
}

function Get-SlackExePath {
    $p = Get-Process slack -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        try { if ($p.Path -and (Test-Path $p.Path)) { return $p.Path } } catch {}
    }
    $base = Join-Path $env:LOCALAPPDATA 'slack'
    if (Test-Path $base) {
        $exe = Get-ChildItem $base -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'slack.exe' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($exe) { return $exe }
    }
    $cmd = Get-Command slack.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

function Stop-SlackForPatch {
    $running = @(Get-Process slack -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return $false }
    Write-ShinyLog "Stopping Slack for safe cache patch"
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i=0; $i -lt 50; $i++) {
        if (!(Get-Process slack -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    throw "Slack did not fully stop."
}

function Start-SlackAfterPatch {
    param([string]$ExePath)
    if ($ExePath -and (Test-Path $ExePath)) {
        Start-Process $ExePath | Out-Null
        Write-ShinyLog "Relaunched Slack: $ExePath"
        return
    }
    try {
        Start-Process 'slack:' | Out-Null
        Write-ShinyLog "Relaunched Slack via URI"
    } catch {
        Write-ShinyLog "Could not relaunch Slack automatically."
    }
}

function Invoke-ShinyRepair {
    param([bool]$RestartSlack = $true, [switch]$Quiet)

    $root = Get-ShinySlackRoot
    $cache = Get-SlackCacheDir
    if (!(Test-Path $cache)) { throw "Slack cache not found: $cache" }

    # Fast path: if the saved region is readable and already contains the
    # custom payload, do not disturb a running Slack session.
    $health = Get-ShinyStateHealth
    if ($health -eq 'Custom') {
        if (!$Quiet) { Write-Host 'ShinySlack: already healthy.' }
        return 'Healthy'
    }

    $wasRunning = [bool](Get-Process slack -ErrorAction SilentlyContinue)
    $slackExe = Get-SlackExePath
    $stoppedForPatch = $false

    # Chromium keeps the block-cache data_* files locked while Slack is open.
    # Discovery/scanning must happen after Slack is fully stopped. This also
    # prevents Slack from treating a live edit as corruption and re-fetching it.
    if ($wasRunning) {
        if (!$RestartSlack) { return 'NeedsRestart' }
        Stop-SlackForPatch | Out-Null
        $stoppedForPatch = $true
        Start-Sleep -Milliseconds 800
    }

    try {
        $stockFile = Ensure-StockReference
        $stockBytes = [IO.File]::ReadAllBytes($stockFile)
        $slot = $stockBytes.Length
        $customFile = Ensure-CustomPrepared -SlotLength $slot
        $customBytes = [IO.File]::ReadAllBytes($customFile)
        $padded = New-PaddedCustomBytes -CustomBytes $customBytes -SlotLength $slot
        $stockHash = Get-Sha256Hex $stockBytes
        $customHash = Get-Sha256Hex $padded

        # Slack is closed here, so full-cache exact scans are safe.
        $customHit = Find-ExactRegion -Needle $padded -CacheDir $cache
        if ($customHit) {
            Save-ShinyState -File $customHit.File -Offset $customHit.Offset -SlotLength $slot -StockHash $stockHash -CustomHash $customHash
            if (!$Quiet) { Write-Host 'ShinySlack: custom sound already present.' }
            return 'Healthy'
        }

        $stockHit = Find-ExactRegion -Needle $stockBytes -CacheDir $cache
        if (!$stockHit) {
            # Slack may have updated its CDN asset. Refresh the reference once
            # while the cache is unlocked, then retry by exact SHA-256 match.
            $stockFile = Ensure-StockReference -ForceRefresh
            $stockBytes = [IO.File]::ReadAllBytes($stockFile)
            $slot = $stockBytes.Length
            $customFile = Ensure-CustomPrepared -SlotLength $slot
            $customBytes = [IO.File]::ReadAllBytes($customFile)
            $padded = New-PaddedCustomBytes -CustomBytes $customBytes -SlotLength $slot
            $stockHash = Get-Sha256Hex $stockBytes
            $customHash = Get-Sha256Hex $padded
            $stockHit = Find-ExactRegion -Needle $stockBytes -CacheDir $cache
        }

        if (!$stockHit) {
            throw "Exact stock Knock Brush body not found. Reopen Slack, select Knock Brush, trigger one REAL incoming notification, then click Apply/Repair again."
        }

        $backupDir = Join-Path $root 'backups'
        if (!(Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $backup = Join-Path $backupDir ("{0}_{1}.bak" -f ([IO.Path]::GetFileName($stockHit.File)), (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Copy-Item $stockHit.File $backup -Force

        $fs = [IO.File]::Open($stockHit.File, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $fs.Position = [long]$stockHit.Offset
            $fs.Write($padded, 0, $padded.Length)
            $fs.Flush()
        } finally {
            $fs.Close()
        }

        $verify = Read-RegionBytes -File $stockHit.File -Offset $stockHit.Offset -Length $slot
        if ($null -eq $verify -or (Get-Sha256Hex $verify) -ne $customHash) {
            throw "Patch verification failed. Backup preserved at $backup"
        }

        Save-ShinyState -File $stockHit.File -Offset $stockHit.Offset -SlotLength $slot -StockHash $stockHash -CustomHash $customHash
        Write-ShinyLog "Patched $($stockHit.File) at 0x$('{0:X}' -f $stockHit.Offset); custom=$($customBytes.Length), slot=$slot"

        if (!$Quiet) {
            Write-Host "SHINY PATCHED: $($customBytes.Length) custom bytes / $slot-byte slot"
        }
        return 'Patched'
    }
    finally {
        if ($stoppedForPatch -and $RestartSlack) {
            Start-SlackAfterPatch -ExePath $slackExe
        }
    }
}
