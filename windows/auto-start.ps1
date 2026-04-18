# ============================================================================
# auto-start.ps1 — Windows logon orchestration for Remote VS Code
# ----------------------------------------------------------------------------
# Runs at Windows logon via Task Scheduler. Brings the full stack online:
#
#   1. Wait for DNS (Cloudflare edge) to be reachable
#   2. Wait for WSL to accept commands as the target user
#   3. Launch code-server inside WSL
#   4. Probe http://127.0.0.1:<PORT> until it responds
#   5. Start the Cloudflare Tunnel pointing at the local code-server
#
# Any stage retries on failure. If the stack isn't up after all retries,
# the script logs FAILED and exits — check E:\code\startup.log.
#
# IMPORTANT: The HTTP probe uses 127.0.0.1 (IPv4), NOT localhost. PowerShell
# resolves `localhost` to IPv6 ::1 first, but WSL2's localhost-forwarding
# is IPv4-only. Using 127.0.0.1 avoids a 45-second timeout loop at logon.
# ============================================================================

$ErrorActionPreference = "Stop"

# ----- CONFIG — edit these to match your setup ------------------------------
$WSL_USER = "admin"                 # WSL user that owns code-server
$PORT     = 8081                    # Port code-server binds to in WSL
$TUNNEL   = "dev-tunnel"            # cloudflared tunnel name
$LOG      = "E:\code\startup.log"   # Transcript file
# ----------------------------------------------------------------------------

Start-Transcript -Path $LOG -Append

function Retry($action, $name, $max = 5) {
    for ($i = 1; $i -le $max; $i++) {
        try {
            Write-Host "[$name] Attempt $i"
            & $action
            return
        } catch {
            Start-Sleep 3
        }
    }
    throw "$name failed after $max attempts"
}

function Wait-Network {
    # Resolve a Cloudflare tunnel edge hostname to confirm DNS + internet are up.
    # If this fails, the tunnel has no chance of connecting anyway.
    Retry {
        Resolve-DnsName region1.v2.argotunnel.com -ErrorAction Stop | Out-Null
    } "DNS Ready" 10
}

function Ensure-WSL {
    # WSL sometimes lags at logon; a trivial command proves it's ready.
    Retry {
        wsl -u $WSL_USER -e bash -lc "echo ready" | Out-Null
    } "WSL Ready"
}

function Start-CodeServer {
    # Kill anything holding the port from a previous session, then launch.
    Retry {
        wsl -u $WSL_USER -e bash -lc "fuser -k ${PORT}/tcp 2>/dev/null || true"
        Start-Sleep 1
        wsl -u $WSL_USER -e bash -lc "/home/$WSL_USER/start-code-server.sh"
    } "Start Code Server"
}

function Wait-HTTP {
    # Confirm code-server is actually serving before we start the tunnel.
    # 127.0.0.1 (not localhost) — see header comment for why.
    Retry {
        $r = Invoke-WebRequest "http://127.0.0.1:$PORT" -TimeoutSec 3 -UseBasicParsing
        if ($r.StatusCode -lt 200) { throw "bad status" }
    } "HTTP Ready" 15
}

function Start-Tunnel {
    # Kill any stale cloudflared, then relaunch hidden.
    Retry {
        Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Process cloudflared -ArgumentList "tunnel run $TUNNEL" -WindowStyle Hidden
        Start-Sleep 5

        # Sanity check — hit the local endpoint once more to confirm stability.
        $r = Invoke-WebRequest "http://127.0.0.1:$PORT" -TimeoutSec 3 -UseBasicParsing
        if (-not $r) { throw "Tunnel not stable" }
    } "Tunnel Start" 5
}

try {
    Write-Host "=== Dev Startup ==="

    # Windows finishes logon before network/WSL are actually ready. A pause
    # here costs nothing and prevents the first few retries from wasting
    # time failing for reasons unrelated to the script.
    Start-Sleep 30

    Wait-Network
    Ensure-WSL
    Start-CodeServer
    try {
        Wait-HTTP
    } catch {
        # The tunnel will retry the origin on its own, so don't let an HTTP
        # probe hiccup prevent the tunnel from starting. Log and continue.
        Write-Host "WARN: HTTP probe failed, starting tunnel anyway"
    }
    Start-Tunnel

    Write-Host "READY -> https://dev.yourdomain.com"
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
}
finally {
    Stop-Transcript
}
