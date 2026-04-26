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

$h = Get-StackHealth
if ($h.Healthy) {
    Write-Log "OK $($h.Summary)"
    exit 0
}

Write-Log "UNHEALTHY $($h.Summary) -- invoking auto-start.ps1 -NoLogonDelay"
$autoStart = Join-Path $PSScriptRoot "auto-start.ps1"
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $autoStart -NoLogonDelay 2>&1 |
        ForEach-Object { Write-Log "  heal> $_" }
    $healExit = $LASTEXITCODE
} catch {
    Write-Log "HEAL EXCEPTION: $($_.Exception.Message)"
    exit 1
}

# Re-probe to confirm recovery; mirror code-server log post-heal too.
Start-Sleep 3
Update-CodeServerLogMirror
$h = Get-StackHealth
if ($h.Healthy) {
    Write-Log "RECOVERED $($h.Summary) (heal exit=$healExit)"
    exit 0
} else {
    Write-Log "STILL UNHEALTHY $($h.Summary) (heal exit=$healExit) -- will retry next cycle"
    exit 1
}
