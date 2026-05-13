# ============================================================================
# health-check.ps1 -- watchdog + auto-heal for the remote-VS-Code stack
# ----------------------------------------------------------------------------
# Runs every 2 minutes via Task Scheduler "Dev Environment Health Check".
#
# HEALTH MODEL: three independent probes; ALL must pass for "healthy".
#
#   1. cloudflared process is alive on this Windows host
#   2. local origin (http://127.0.0.1:$PORT) responds 2xx-4xx
#   3. public URL (https://$PUBLIC_HOST) responds 2xx-4xx
#
# Why all three: Cloudflare Access serves its login page from the EDGE
# without contacting the origin. So probe #3 alone returns 200 even when the
# tunnel and code-server are dead -- which is exactly what bit RCA-007.
#
# LOGGING: every probe records *what* failed, not just *that* it failed.
#   OK         cloudflared=alive(PID=21188) origin=200 public=200
#   UNHEALTHY  cloudflared=DEAD origin=conn-refused public=200
#   UNHEALTHY  cloudflared=alive(PID=12345) origin=200 public=timeout
#
# Each cycle also mirrors /tmp/code-server.log (in WSL) to logs/code-server.log
# so the operator has all four log streams in one directory.
#
# OPERATIONAL NOTES:
#   - Append-only log at $LOG_HEALTH. Rotates at ~10MB.
#   - Exit code: 0 on healthy or successful heal, 1 if heal failed,
#     2 if config missing.
#   - Task Scheduler trigger should set "Do not start a new instance".
# ============================================================================

$ErrorActionPreference = "Stop"

$ConfigPath = "E:\code\auto-start.config.ps1"
if (-not (Test-Path $ConfigPath)) {
    $fallback = Join-Path $env:TEMP "health-check.failure.log"
    "$(Get-Date -Format o) FAILED: config not found at $ConfigPath" |
        Out-File -FilePath $fallback -Append
    exit 2
}
. $ConfigPath

$logDir     = Split-Path $LOG
$LOG_HEALTH = Join-Path $logDir "health-check.log"
$LOG_CS     = Join-Path $logDir "code-server.log"
$LOG_CF     = Join-Path $logDir "cloudflared.log"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

# Cheap log rotation: if the file is over 10MB, archive and start fresh.
if ((Test-Path $LOG_HEALTH) -and ((Get-Item $LOG_HEALTH).Length -gt 10MB)) {
    $archive = "$LOG_HEALTH.1"
    if (Test-Path $archive) { Remove-Item $archive -Force }
    Rename-Item $LOG_HEALTH $archive
}

function Write-Log($msg) {
    "$(Get-Date -Format o) $msg" | Out-File -FilePath $LOG_HEALTH -Append -Encoding ascii
}

function Invoke-CloudflaredLogRotation {
    # cloudflared has no built-in log rotation. Threshold is higher than the
    # watchdog's own log because rotation requires stopping the daemon to
    # release the file handle on Windows (~2-5s tunnel blip). We accept ~50MB
    # of disk before paying that cost. The next health probe after rotation
    # detects cloudflared=DEAD and the standard heal-flow brings it back up.
    if (-not (Test-Path $LOG_CF)) { return }
    if ((Get-Item $LOG_CF).Length -le 50MB) { return }

    Write-Log "ROTATE cloudflared.log >50MB -- stopping cloudflared to release handle"
    $archive = "$LOG_CF.1"
    if (Test-Path $archive) { Remove-Item $archive -Force }

    $proc = Get-Process cloudflared -ErrorAction SilentlyContinue
    if ($proc) {
        try { $proc | Stop-Process -Force; Start-Sleep 2 }
        catch {
            Write-Log "ROTATE: could not stop cloudflared ($($_.Exception.Message)) -- skipping rotation"
            return
        }
    }
    try {
        Rename-Item $LOG_CF $archive -Force
        Write-Log "ROTATE complete -- next probe will trigger heal to restart cloudflared"
    } catch {
        Write-Log "ROTATE rename failed: $($_.Exception.Message)"
    }
}

function Send-Heartbeat($state) {
    # Dead-man's-switch ping to Healthchecks.io (or any compatible service).
    # If no $HEALTHCHECK_URL is configured, this is a no-op.
    # State: 'ok' for healthy/recovered, 'fail' for STILL UNHEALTHY.
    # The heartbeat call must NEVER affect health-check itself -- a network
    # blip to healthchecks.io is the case we most want to alert on, and
    # silently failing to ping is the correct behavior (next cycle will
    # succeed, or the external monitor will alert when no ping arrives).
    if (-not $HEALTHCHECK_URL) { return }
    $url = if ($state -eq 'fail') { "$HEALTHCHECK_URL/fail" } else { $HEALTHCHECK_URL }
    try { Invoke-WebRequest $url -TimeoutSec 5 -UseBasicParsing | Out-Null } catch {}
}

function Get-CloudflaredMetricsSummary {
    # Scrape cloudflared's Prometheus metrics endpoint and extract a few
    # high-signal counters. Appended to every OK / UNHEALTHY / RECOVERED log
    # line so we can chart tunnel-side errors over time and spot a counter
    # spike that precedes a user-visible failure. Best-effort; if the
    # endpoint is unreachable (cloudflared dead), returns "metrics=down".
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:20241/metrics' `
                 -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $lines = $r.Content -split "`n"
        $reqs   = ($lines | Where-Object { $_ -match '^cloudflared_tunnel_total_requests\s+(\d+)' }   | ForEach-Object { $matches[1] } | Select-Object -First 1)
        $errs   = ($lines | Where-Object { $_ -match '^cloudflared_tunnel_request_errors\s+(\d+)' }   | ForEach-Object { $matches[1] } | Select-Object -First 1)
        $ha     = ($lines | Where-Object { $_ -match '^cloudflared_tunnel_ha_connections\s+(\d+)' }   | ForEach-Object { $matches[1] } | Select-Object -First 1)
        $procErr= ($lines | Where-Object { $_ -match '^cloudflared_proxy_connect_streams_errors\s+(\d+)' } | ForEach-Object { $matches[1] } | Select-Object -First 1)
        return "mx=reqs:${reqs} errs:${errs} ha:${ha} proxyerr:${procErr}"
    } catch {
        return "mx=down"
    }
}

function Capture-FailureSnapshot($summary) {
    # Forensic dump produced once per UNHEALTHY detection, before invoking
    # heal. The 2026-05-11 public=timeout events were undiagnosable in
    # hindsight because we had no network-state snapshot at the moment of
    # failure. Each snapshot is one timestamped file in logs/failure-*.txt.
    # On a healthy stack this is never written; on an unhealthy one it's
    # ~10-30KB of text covering everything an incident-responder would need.
    $ts  = Get-Date -Format "yyyyMMdd-HHmmss"
    $out = Join-Path $logDir "failure-$ts.txt"
    $sb  = New-Object System.Text.StringBuilder

    function Add($t) { [void]$sb.AppendLine($t) }

    Add "=== Failure Snapshot $((Get-Date).ToString('o')) ==="
    Add "Trigger: $summary"
    Add ""

    Add "=== Network Adapters ==="
    try { Add ((Get-NetAdapter | Format-Table Name, Status, LinkSpeed, MediaConnectionState -AutoSize | Out-String).TrimEnd()) }
    catch { Add "ERR: $($_.Exception.Message)" }
    Add ""

    Add "=== DNS Resolvers (IPv4) ==="
    try { Add ((Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | Format-Table InterfaceAlias, ServerAddresses -AutoSize | Out-String).TrimEnd()) }
    catch { Add "ERR: $($_.Exception.Message)" }
    Add ""

    Add "=== Default Route / Gateway ==="
    try { Add ((Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Format-Table InterfaceAlias, NextHop, RouteMetric -AutoSize | Out-String).TrimEnd()) }
    catch { Add "ERR: $($_.Exception.Message)" }
    Add ""

    Add "=== TCP Reachability Tests ==="
    foreach ($target in @(
        @{H='1.1.1.1';      P=443},
        @{H='8.8.8.8';      P=443},
        @{H='cloudflare.com'; P=443}
    )) {
        $ok = $false
        try {
            $ok = Test-NetConnection -ComputerName $target.H -Port $target.P `
                      -InformationLevel Quiet -WarningAction SilentlyContinue
        } catch {}
        Add ("{0,-20} -> {1}" -f "$($target.H):$($target.P)", $ok)
    }
    Add ""

    Add "=== cloudflared metrics (key counters) ==="
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:20241/metrics' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $r.Content -split "`n" |
            Where-Object {
                $_ -match '^cloudflared_(tunnel_total_requests|tunnel_request_errors|tunnel_ha_connections|tunnel_concurrent|tunnel_response_by_code|tunnel_tunnel_register_fail|proxy_connect_streams_errors|tcp_active_sessions|tcp_total_sessions|tunnel_server_locations)'
            } |
            ForEach-Object { Add $_ }
    } catch {
        Add "ERR: $($_.Exception.Message)  (cloudflared metrics endpoint unreachable -- daemon likely down)"
    }
    Add ""

    Add "=== Windows Event Log slice (last 5 minutes, network-relevant only) ==="
    $since = (Get-Date).AddMinutes(-5)

    # Channel -> filter to keep noise out. The System channel in particular is
    # dominated by GPU power-state and SCM messages on a typical laptop; we
    # only want network/disk/kernel signals for incident diagnosis.
    $channelConfig = @(
        @{
            Name      = 'System'
            Levels    = @(1, 2, 3)   # Critical, Error, Warning -- skip Information noise
            SkipIds   = @(9007, 9008) # NVIDIA RTD3 power-state churn
            Providers = $null
        },
        @{ Name='Microsoft-Windows-DNS-Client/Operational';      Levels=$null; SkipIds=@(); Providers=$null },
        @{ Name='Microsoft-Windows-NetworkProfile/Operational';  Levels=$null; SkipIds=@(); Providers=$null },
        @{ Name='Microsoft-Windows-NCSI/Operational';            Levels=$null; SkipIds=@(); Providers=$null },
        @{ Name='Microsoft-Windows-WLAN-AutoConfig/Operational'; Levels=$null; SkipIds=@(); Providers=$null }
    )

    foreach ($c in $channelConfig) {
        Add "--- $($c.Name) ---"
        $filter = @{ LogName = $c.Name; StartTime = $since }
        if ($c.Levels) { $filter.Level = $c.Levels }

        $evts = $null
        try {
            $evts = Get-WinEvent -FilterHashtable $filter -MaxEvents 50 -ErrorAction Stop |
                    Where-Object { $c.SkipIds -notcontains $_.Id } |
                    Sort-Object TimeCreated
        } catch {
            if ($_.Exception.Message -match 'No events were found') {
                Add "(no matching events in window)"
            } else {
                Add "(channel error: $($_.Exception.Message))"
            }
            Add ""
            continue
        }
        if (-not $evts) {
            Add "(no matching events in window)"
        } else {
            foreach ($e in $evts) {
                $firstline = if ($e.Message) { ($e.Message -split "`r?`n" | Select-Object -First 1).Trim() } else { '' }
                Add ("{0} [{1}] Id={2} {3}: {4}" -f
                     $e.TimeCreated.ToString('HH:mm:ss'),
                     $e.LevelDisplayName,
                     $e.Id,
                     $e.ProviderName,
                     $firstline)
            }
        }
        Add ""
    }

    try {
        $sb.ToString() | Out-File -FilePath $out -Encoding utf8
        Write-Log "SNAPSHOT written to $out"
    } catch {
        Write-Log "SNAPSHOT write failed: $($_.Exception.Message)"
    }
}

function Get-HttpStatusOrError($url, $timeoutSec) {
    # Returns "<status-code>" on success, or a short symbolic error on failure.
    # Symbolic errors are normalized so log output stays grep-friendly.
    try {
        $r = Invoke-WebRequest $url -TimeoutSec $timeoutSec -UseBasicParsing -ErrorAction Stop
        return "$($r.StatusCode)"
    } catch {
        $resp = $_.Exception.Response
        if ($null -ne $resp) {
            try { return "$([int]$resp.StatusCode)" } catch { return "ERR" }
        }
        $msg = $_.Exception.Message
        if     ($msg -match "actively refused")        { return "conn-refused" }
        elseif ($msg -match "timed out")               { return "timeout" }
        elseif ($msg -match "could not be resolved")   { return "dns-fail" }
        elseif ($msg -match "remote name could not")   { return "dns-fail" }
        elseif ($msg -match "trust|certificate")       { return "tls-error" }
        elseif ($msg -match "Unable to connect")       { return "no-route" }
        else                                           { return "ERR:$($_.Exception.GetType().Name)" }
    }
}

function Get-StackHealth {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $proc = Get-Process cloudflared -ErrorAction SilentlyContinue
    $cf = if ($proc) { "alive(PID=$($proc.Id))" } else { "DEAD" }

    $origin = Get-HttpStatusOrError "http://127.0.0.1:$PORT" 5
    $public = Get-HttpStatusOrError "https://$PUBLIC_HOST" 10

    $healthy = ($cf -ne "DEAD") -and `
               ($origin -match "^[234]\d\d$") -and `
               ($public -match "^[234]\d\d$")

    return @{
        Summary = "cloudflared=$cf origin=$origin public=$public"
        Healthy = $healthy
    }
}

function Update-CodeServerLogMirror {
    # Mirror /tmp/code-server.log (in WSL) to logs/code-server.log so all
    # four log streams live in one directory. Best-effort: if WSL is hung
    # or the source is missing, swallow silently -- the watchdog's own
    # health logging is the authoritative signal.
    try {
        $wslLogsDir = "/mnt/" + ($logDir.Substring(0,1).ToLower()) +
                      ($logDir.Substring(2) -replace '\\', '/')
        $wslArgs = if ($WSL_DISTRO) { @('-d', $WSL_DISTRO, '-u', $WSL_USER) }
                   else             { @('-u', $WSL_USER) }
        $cmd = "test -f /tmp/code-server.log && cp /tmp/code-server.log '$wslLogsDir/code-server.log' 2>/dev/null; true"
        & wsl @wslArgs -e bash -lc $cmd 2>$null | Out-Null
    } catch {
        # Don't let log-mirror failure affect health reporting.
    }
}

# ===== main flow ============================================================

Update-CodeServerLogMirror
Invoke-CloudflaredLogRotation

$h  = Get-StackHealth
$mx = Get-CloudflaredMetricsSummary
if ($h.Healthy) {
    Write-Log "OK $($h.Summary) $mx"
    Send-Heartbeat 'ok'
    exit 0
}

Write-Log "UNHEALTHY $($h.Summary) $mx -- invoking auto-start.ps1 -NoLogonDelay"

# Forensic capture BEFORE the heal mutates anything. Snapshots only land on
# unhealthy cycles (rare), so disk impact is negligible. See RCA-008 for the
# diagnostic gap this closes.
Capture-FailureSnapshot $h.Summary

$autoStart = Join-Path $PSScriptRoot "auto-start.ps1"
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $autoStart -NoLogonDelay 2>&1 |
        ForEach-Object { Write-Log "  heal> $_" }
    $healExit = $LASTEXITCODE
} catch {
    Write-Log "HEAL EXCEPTION: $($_.Exception.Message)"
    Send-Heartbeat 'fail'
    exit 1
}

# Re-probe to confirm recovery; mirror code-server log post-heal too.
Start-Sleep 3
Update-CodeServerLogMirror
$h  = Get-StackHealth
$mx = Get-CloudflaredMetricsSummary
if ($h.Healthy) {
    Write-Log "RECOVERED $($h.Summary) $mx (heal exit=$healExit)"
    Send-Heartbeat 'ok'
    exit 0
} else {
    Write-Log "STILL UNHEALTHY $($h.Summary) $mx (heal exit=$healExit) -- will retry next cycle"
    Send-Heartbeat 'fail'
    exit 1
}
