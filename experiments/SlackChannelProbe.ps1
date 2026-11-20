param(
    [int]$Port = 9229
)

$ErrorActionPreference = 'Stop'

function Write-Probe {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts $Message"
    Write-Host $line
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
}

function Find-SlackExe {
    $base = Join-Path $env:LOCALAPPDATA 'slack'
    if(!(Test-Path $base)) { return $null }

    $apps = Get-ChildItem $base -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending

    foreach($app in $apps) {
        $candidate = Join-Path $app.FullName 'slack.exe'
        if(Test-Path $candidate) { return $candidate }
    }

    $fallback = Join-Path $base 'slack.exe'
    if(Test-Path $fallback) { return $fallback }

    return $null
}

function Get-CdpTargets {
    param([int]$Port)
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2
}

function Receive-CdpMessage {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$TimeoutMs = 10000
    )

    $buffer = New-Object byte[] 65536
    $segment = New-Object System.ArraySegment[byte] -ArgumentList (, $buffer)
    $stream = New-Object System.IO.MemoryStream
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutMs)

    try {
        do {
            $result = $Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            if($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw "Slack DevTools socket closed."
            }
            $stream.Write($buffer, 0, $result.Count)
        } while(!$result.EndOfMessage)

        return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    finally {
        $stream.Dispose()
        $cts.Dispose()
    }
}

function Send-Cdp {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Compress -Depth 8

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $Socket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()
}

function Invoke-Cdp {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [ref]$NextId,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $id = $NextId.Value
    $NextId.Value++

    Send-Cdp -Socket $Socket -Id $id -Method $Method -Params $Params

    while($true) {
        $raw = Receive-CdpMessage -Socket $Socket -TimeoutMs 15000
        $msg = $raw | ConvertFrom-Json
        if($msg.id -eq $id) {
            if($msg.error) {
                throw ("CDP error for {0}: {1}" -f $Method, ($msg.error | ConvertTo-Json -Compress))
            }
            return $msg.result
        }
    }
}

$root = Join-Path $env:LOCALAPPDATA 'ShinySlack'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$script:LogPath = Join-Path $root 'channel-probe.log'

Write-Probe "ShinySlack channel probe starting. Port=$Port"
Write-Probe "Privacy mode: only team/channel IDs and timestamps are recorded. Message text is not collected."

$slackProc = Get-Process slack -ErrorAction SilentlyContinue
if($slackProc) {
    Write-Probe "Slack is already running. Probe will NOT close it automatically."
    Write-Probe "Close Slack normally, then run this probe again."
    exit 2
}

$slack = Find-SlackExe
if(!$slack) {
    Write-Probe "Slack executable not found under %LOCALAPPDATA%\slack."
    exit 3
}

Write-Probe "Launching Slack with a temporary localhost DevTools port."
Write-Probe "Security note: keep this probe temporary; do not leave remote debugging enabled after testing."

$slackArgs = @(
    "--remote-debugging-address=127.0.0.1",
    "--remote-debugging-port=$Port",
    "--remote-allow-origins=http://127.0.0.1:$Port"
)

Start-Process -FilePath $slack -ArgumentList $slackArgs | Out-Null

$targets = $null
for($i=0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $targets = Get-CdpTargets -Port $Port
        if($targets) { break }
    } catch {}
}

if(!$targets) {
    Write-Probe "Could not reach Slack DevTools endpoint on localhost:$Port."
    exit 4
}

$target = $targets |
    Where-Object {
        $_.type -eq 'page' -and (
            $_.url -match 'app\.slack\.com' -or
            $_.title -match 'Slack|Amazon'
        )
    } |
    Select-Object -First 1

if(!$target) {
    Write-Probe "DevTools is live, but no Slack page target was found."
    Write-Probe "Available targets:"
    foreach($t in $targets) {
        Write-Probe ("  type={0} title={1} url={2}" -f $t.type, $t.title, $t.url)
    }
    exit 5
}

Write-Probe ("Attached target: {0} | {1}" -f $target.title, $target.url)

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.Options.SetRequestHeader('Origin', "http://127.0.0.1:$Port")
$uri = [Uri]$target.webSocketDebuggerUrl
$ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

$nextId = 1
Invoke-Cdp -Socket $ws -NextId ([ref]$nextId) -Method 'Runtime.enable' | Out-Null

$inject = @'
(() => {
  if (window.__ShinySlackChannelProbeInstalled) {
    return 'already-installed';
  }

  window.__ShinySlackChannelProbeInstalled = true;
  window.__ShinySlackChannelProbeEvents = [];

  const recordBody = (body) => {
    try {
      if (typeof body !== 'string' || !body.includes('notification:sent')) return;
      const data = JSON.parse(body);
      if (!Array.isArray(data.spans)) return;

      for (const span of data.spans) {
        if (!span || span.name !== 'notification:sent' || !Array.isArray(span.tags)) continue;

        let teamId = null;
        let channelId = null;

        for (const tag of span.tags) {
          if (!tag) continue;
          if (tag.key === 'encoded_team_id') teamId = tag.v_str || null;
          if (tag.key === 'encoded_channel_id') channelId = tag.v_str || null;
        }

        if (teamId && channelId) {
          window.__ShinySlackChannelProbeEvents.push({
            ts: new Date().toISOString(),
            teamId,
            channelId
          });
        }
      }
    } catch (_) {}
  };

  const originalFetch = window.fetch;
  window.fetch = function(input, init) {
    try {
      if (init && typeof init.body === 'string') recordBody(init.body);
    } catch (_) {}
    return originalFetch.apply(this, arguments);
  };

  const originalBeacon = navigator.sendBeacon.bind(navigator);
  navigator.sendBeacon = function(url, data) {
    try {
      if (typeof data === 'string') recordBody(data);
    } catch (_) {}
    return originalBeacon(url, data);
  };

  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    try {
      if (typeof body === 'string') recordBody(body);
    } catch (_) {}
    return originalSend.apply(this, arguments);
  };

  return 'installed';
})()
'@

$result = Invoke-Cdp -Socket $ws -NextId ([ref]$nextId) -Method 'Runtime.evaluate' -Params @{
    expression = $inject
    returnByValue = $true
}

$installState = $result.result.value
Write-Probe ("Renderer probe state: {0}" -f $installState)
Write-Probe "READY. Send/receive real Slack notifications from known channels."
Write-Probe "Press Ctrl+C when finished."

$pollExpr = @'
(() => {
  const events = window.__ShinySlackChannelProbeEvents || [];
  window.__ShinySlackChannelProbeEvents = [];
  return JSON.stringify(events);
})()
'@

try {
    while($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        Start-Sleep -Milliseconds 750

        try {
            $result = Invoke-Cdp -Socket $ws -NextId ([ref]$nextId) -Method 'Runtime.evaluate' -Params @{
                expression = $pollExpr
                returnByValue = $true
            }

            $json = $result.result.value
            if($json -and $json -ne '[]') {
                $events = $json | ConvertFrom-Json
                foreach($event in @($events)) {
                    Write-Probe ("NOTIFICATION team={0} channel={1} eventTs={2}" -f $event.teamId, $event.channelId, $event.ts)
                }
            }
        }
        catch {
            Write-Probe ("Probe polling error: {0}" -f $_.Exception.Message)
            break
        }
    }
}
finally {
    try {
        if($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $ws.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                'probe complete',
                [System.Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()
        }
    } catch {}
    $ws.Dispose()
    Write-Probe "Channel probe stopped. Slack can remain open, but restart Slack normally to remove remote-debug mode."
}
