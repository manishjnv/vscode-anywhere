# ============================================================================
# auto-start.ps1 -- Windows logon orchestration for Remote VS Code
# ----------------------------------------------------------------------------
# Runs at Windows logon via Task Scheduler. Brings the full stack online:
#
#   1. Wait for DNS / internet
#   2. Wait for WSL to accept commands as the target user
#   3. Launch code-server inside WSL    (skip if already healthy)
#   4. Probe http://127.0.0.1:<PORT> until it responds
#   5. Start the Cloudflare Tunnel      (skip if already serving the public URL)
#
# Each stage is IDEMPOTENT -- re-running the script while the stack is up
# does NOT kill working processes. This is what lets you safely run it
# manually any time without dropping in-browser code-server sessions, and it
# dodges the "Stop-Process: Access is denied" failure that happens when a
# non-elevated manual re-run tries to kill an elevated Task-Scheduler
# cloudflared.
#
# Real values (WSL user, port, tunnel name, public hostname, log path) live
# in $ConfigPath -- see auto-start.config.example.ps1 for the required vars.
# That file is .gitignored so this template stays generic in the public repo.
#
# ENCODING: this file MUST be saved as ASCII or UTF-8 with BOM. Plain UTF-8
# without BOM gets reinterpreted by Windows PowerShell 5.1 as CP-1252, and
# any non-ASCII char (em-dash, smart quote) breaks the parser. Stick to ASCII.
#
# IMPORTANT: HTTP probes use 127.0.0.1 (IPv4), NOT localhost. PowerShell
# resolves `localhost` to IPv6 ::1 first, but WSL2's localhost-forwarding is
# IPv4-only -- using `localhost` causes a 45-second timeout loop at logon.
#
# -NoLogonDelay: skip the 30-second sleep at the top. Used by health-check.ps1
# when invoking this script as the auto-heal action mid-session (the delay
# only makes sense at fresh logon when WSL/network are still warming up).
# ============================================================================

[CmdletBinding()]
param([switch]$NoLogonDelay)

$ErrorActionPreference = "Stop"

# ----- CONFIG --------------------------------------------------------------
# Local config file with real values. Adjust this path if your deployment
# lives somewhere else.
$ConfigPath = "E:\code\auto-start.config.ps1"
# ---------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    # Fall back to %TEMP% so a missing config doesn't fail silently at logon.
    $fallback = Join-Path $env:TEMP "auto-start.failure.log"
    "$(Get-Date -Format o) FAILED: config not found at $ConfigPath" |
        Out-File -FilePath $fallback -Append
    throw "Missing config: $ConfigPath (see auto-start.config.example.ps1)"
}
. $ConfigPath  # provides $WSL_USER, $WSL_DISTRO, $PORT, $TUNNEL, $PUBLIC_HOST, $LOG

# Best-effort time resync. After a long sleep / battery drain the laptop clock
# can drift by minutes; the first TLS handshake to Cloudflare then fails with
# "cert not yet valid" or "expired", which the watchdog cannot distinguish
# from a real outage. w32tm is silent on systems where the Time service is
# disabled by policy; we swallow errors because this is a hardening step.
try { & w32tm /resync /force 2>&1 | Out-Null } catch {}

# Make sure the log directory exists BEFORE Start-Transcript, otherwise a
# missing parent dir on first boot would abort the script with no transcript.
$logDir = Split-Path $LOG
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

# Cheap log rotation: mirrors the pattern in health-check.ps1. Without this,
# Start-Transcript -Append grows the file indefinitely; observed ~800KB over
# 4 months and there is no upper bound. 10MB cap with a single .1 archive
# keeps roughly the last 1-2 months of detailed heal transcripts.
if ((Test-Path $LOG) -and ((Get-Item $LOG).Length -gt 10MB)) {
    $archive = "$LOG.1"
    if (Test-Path $archive) { Remove-Item $archive -Force }
    Rename-Item $LOG $archive
}

Start-Transcript -Path $LOG -Append | Out-Null

function Retry($action, $name, $max = 5) {
    for ($i = 1; $i -le $max; $i++) {
        try {
            Write-Host "[$name] Attempt $i"
            & $action
            return
        } catch {
            # Log the underlying error every attempt -- silent retries cost
            # hours of debugging at logon when nobody is watching the screen.
            Write-Host "[$name] attempt $i failed: $($_.Exception.Message)"
            Start-Sleep 3
        }
    }
    throw "$name failed after $max attempts"
}

function Test-LocalHTTP {
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$PORT" -TimeoutSec 3 -UseBasicParsing
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch { return $false }
}

function Test-PublicTunnel {
    # Any 2xx/3xx/4xx from the public hostname proves Cloudflare -> tunnel ->
    # origin is end-to-end up. A naked 127.0.0.1:$PORT probe cannot tell us
    # whether cloudflared itself is alive -- that is why the old script kept
    # logging READY while the tunnel was actually dead.
    #
    # We FOLLOW redirects: Cloudflare Access bounces unauthenticated requests
    # (302) to <team>.cloudflareaccess.com which returns 200 with the login
    # page. Following the chain works on both PS 5.1 and PS 7+. Using
    # -MaximumRedirection 0 was tried but PS 5.1 throws InvalidOperationException
    # with a NULL .Response on redirect-policy violations, defeating the
    # status-code inspection that works in PS 7+.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-WebRequest "https://$PUBLIC_HOST" -TimeoutSec 12 `
                -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch {
        # If the server returned a real HTTP error (4xx/5xx), .Response is set.
        # 4xx still proves the tunnel is up; 5xx is an origin/edge problem.
        $resp = $_.Exception.Response
        if ($null -ne $resp) {
            try { $code = [int]$resp.StatusCode } catch { $code = 0 }
            return ($code -gt 0 -and $code -lt 500)
        }
        return $false
    }
}

function Wait-Network {
    # TCP-connect probe to 1.1.1.1:443 instead of `Resolve-DnsName 1.1.1.1`.
    # The PTR-lookup approach was observed to time out for 16+ seconds per
    # attempt during the 2026-05-11 WAN flap (see RCA-008) -- with 10 retries
    # that's 160+ seconds of idle time on a script that has nothing else to
    # do until the network is up. Test-NetConnection -Port 443 fails in
    # ~1 second when unreachable and succeeds in <100 ms when up. Same
    # signal ("can we reach the public internet"), one-tenth the latency
    # on the failure path.
    Retry {
        $ok = Test-NetConnection -ComputerName 1.1.1.1 -Port 443 `
                  -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $ok) { throw "TCP connect to 1.1.1.1:443 failed" }
    } "Network Ready" 10
}

function Invoke-WSL($cmd) {
    # Run a bash command inside WSL as $WSL_USER. If $WSL_DISTRO is set, target
    # that distro explicitly; if empty/null, use the default distro (matches
    # what `wsl <args>` does without -d). Native commands don't throw on
    # non-zero exit, so check $LASTEXITCODE explicitly -- otherwise a broken
    # WSL config (e.g., wrong distro, missing user) fails silently.
    if ($WSL_DISTRO) {
        wsl -d $WSL_DISTRO -u $WSL_USER -e bash -lc $cmd
    } else {
        wsl -u $WSL_USER -e bash -lc $cmd
    }
    if ($LASTEXITCODE -ne 0) {
        throw "wsl exited $LASTEXITCODE running: $cmd"
    }
}

function Wait-WSL {
    Retry { Invoke-WSL "echo ready" | Out-Null } "WSL Ready"
}

function Start-CodeServer {
    # Idempotent: if the port already answers, leave the running server alone.
    # Killing it would drop active in-browser sessions for no reason.
    if (Test-LocalHTTP) {
        Write-Host "[Start Code Server] already healthy on :$PORT -- skip"
        return
    }
    Retry {
        Invoke-WSL "fuser -k $PORT/tcp 2>/dev/null; true"
        Start-Sleep 1
        Invoke-WSL "/home/$WSL_USER/start-code-server.sh"
    } "Start Code Server"
}

function Wait-HTTP {
    Retry {
        if (-not (Test-LocalHTTP)) { throw "no response from 127.0.0.1:$PORT" }
    } "HTTP Ready" 15
}

function Start-Tunnel {
    # Fast-path skip requires BOTH (a) cloudflared process alive and (b) the
    # local origin responding. We deliberately do NOT use the public URL as
    # a fast-path signal -- Cloudflare Access serves its login page from the
    # edge without contacting our origin, so a dead local stack would
    # falsely appear healthy. See RCA-007.
    $existing = Get-Process cloudflared -ErrorAction SilentlyContinue
    if ($existing -and (Test-LocalHTTP)) {
        Write-Host "[Tunnel Start] cloudflared alive + origin healthy -- skip"
        return
    }

    Retry {
        # Refresh each attempt -- a previous attempt may have spawned a
        # process that died, leaving a stale handle.
        $current = Get-Process cloudflared -ErrorAction SilentlyContinue
        if ($current) {
            try { $current | Stop-Process -Force -ErrorAction Stop }
            catch {
                $msg = "cannot stop cloudflared (PID $($current.Id)) -- likely "
                $msg += "elevated. Run this script from an elevated shell, or "
                $msg += "stop cloudflared manually before re-running."
                throw $msg
            }
            Start-Sleep 1
        }
        $proc = Start-Process cloudflared -ArgumentList "tunnel run $TUNNEL" `
                    -WindowStyle Hidden -PassThru
        # Wait for cloudflared to settle. We can't reliably probe end-to-end
        # health here (see RCA-007 for why public URL is not a chain signal),
        # so we just confirm the process is still running after a short wait.
        # If registration genuinely failed, the next watchdog cycle catches it.
        Start-Sleep 8
        if ($proc.HasExited) {
            throw "cloudflared exited with code $($proc.ExitCode)"
        }
    } "Tunnel Start" 5
}

try {
    Write-Host "=== Dev Startup ==="

    if (-not $NoLogonDelay) {
        # Windows finishes logon before network/WSL are actually ready. A pause
        # here costs nothing and prevents the first few retries from wasting
        # time failing for reasons unrelated to the script.
        Start-Sleep 30
    }

    Wait-Network
    Wait-WSL
    Start-CodeServer
    try { Wait-HTTP } catch {
        # The tunnel will retry the origin on its own, so don't let an HTTP
        # probe hiccup prevent the tunnel from starting.
        Write-Host "WARN: HTTP probe failed, starting tunnel anyway"
    }
    Start-Tunnel

    Write-Host "READY -> https://$PUBLIC_HOST"
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
}
finally {
    Stop-Transcript | Out-Null
}
