# Monitoring and auto-heal

How the watchdog works, how to install it, how to tell when it has done something for you.

## What it is

[windows/health-check.ps1](../windows/health-check.ps1) -- a small PowerShell script that probes the public URL once per cycle. If healthy, it logs `OK` and exits. If unhealthy, it invokes `auto-start.ps1 -NoLogonDelay` (idempotent: only restarts what's broken), waits 3 seconds, re-probes, and logs `RECOVERED` or `STILL UNHEALTHY`.

A second Task Scheduler task -- "Dev Environment Health Check" -- runs the script every 2 minutes.

## Why this design and not a Windows service

A Windows service running a long-lived daemon would be more "real-time" but adds:

- A second process to debug when something misbehaves.
- A separate update path (service binary vs. script).
- Permission-model complexity (Local System account interactions with WSL are messy).
- A new failure mode: "the watchdog itself crashed."

A scheduled task running a stateless script every 2 minutes:

- Inherits the same identity as `auto-start.ps1` (same user, same elevation).
- Has no in-memory state to lose.
- Re-reads `auto-start.config.ps1` every cycle, picking up config edits without a restart.
- Fails safely: if Task Scheduler doesn't run it, nothing else does either -- you notice the same way you would notice the laptop being off.

The 2-minute granularity is acceptable for a personal dev environment. Cutting it to 30 seconds would buy faster recovery at the cost of running the probe ~2880 times per day (vs ~720) -- both numbers are noise, but `2880 * Invoke-WebRequest` does measurable network traffic against your tunnel.

## What it monitors

**Three independent signals. Health = all three pass.** Per [RCA-007](RCA.md), no single signal is sufficient.

| Signal | Probe | What it covers |
|---|---|---|
| `cloudflared` | `Get-Process cloudflared` | Tunnel daemon alive on this host |
| `origin`      | `Invoke-WebRequest http://127.0.0.1:$PORT` | code-server is bound and serving |
| `public`      | `Invoke-WebRequest https://$PUBLIC_HOST`  | DNS + Cloudflare edge + Access app config |

**Why all three:** Cloudflare Access serves its login page from the edge *without contacting the origin*. So `public` alone returns 200 even when cloudflared and code-server are both dead -- which is exactly what bit RCA-007. `cloudflared` and `origin` together verify the local chain; `public` independently verifies Cloudflare-side configuration.

The probes are deliberately simple and local -- no extra credentials, no service tokens, no Cloudflare API calls. They're cheap enough to run every 2 minutes without measurable cost.

The auto-heal action (`auto-start.ps1 -NoLogonDelay`) is fully idempotent and restarts only the components that are actually broken (each stage in the bring-up has a fast-path skip). So even though the watchdog hands off the entire bring-up, the actual mutation surface is targeted.

See [RELIABILITY.md](RELIABILITY.md) for per-component failure modes and how the auto-heal handles each.

## Install (one-time)

From an **elevated PowerShell** (admin):

```powershell
# Use the .vbs shim so PowerShell starts with no console window at all -- the
# raw `powershell -WindowStyle Hidden` flashes the console briefly every cycle
# before the WindowStyle directive takes effect, producing a popup every 2
# minutes. wscript + run-hidden.vbs avoids the flash entirely.
$action = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument '"E:\code\remote-vscode-wsl-cloudflare\windows\run-hidden.vbs" "E:\code\remote-vscode-wsl-cloudflare\windows\health-check.ps1"' `
    -WorkingDirectory "E:\code\remote-vscode-wsl-cloudflare\windows"

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
    -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName "Dev Environment Health Check" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Probes https://dev.yourdomain.com every 2 minutes; auto-heals via auto-start.ps1 -NoLogonDelay if unhealthy."
```

Key flags explained:

- **`-MultipleInstances IgnoreNew`** -- if a heal cycle is still running when the next 2-minute trigger fires, skip the new fire instead of stacking. Prevents `auto-start.ps1` from running concurrently with itself.
- **`-ExecutionTimeLimit 5 minutes`** -- hard kill if a cycle hangs. The 5-attempt heal budget tops out around 2.5 minutes; 5 is a safe ceiling.
- **`-RunLevel Highest`** -- needed so a `Stop-Process -Force` against an elevated cloudflared (spawned by the logon-time `Dev Environment Startup` task) actually works.
- **`-LogonType Interactive`** -- runs in the user's context, so `wsl` calls reach the right user's distro.

## Verify it's working

```powershell
# Confirm the task exists and last ran successfully
Get-ScheduledTaskInfo -TaskName "Dev Environment Health Check" |
    Select-Object LastRunTime, LastTaskResult, NextRunTime

# Tail the watchdog log
Get-Content E:\code\remote-vscode-wsl-cloudflare\logs\health-check.log -Tail 20 -Wait
```

A healthy stack produces one `OK cloudflared=True origin=True public=True` line every 2 minutes.

## Force a heal to test it

From a non-elevated PowerShell (so you exercise the elevation path):

```powershell
# Kill cloudflared (replace PID with whatever Get-Process returns)
Get-Process cloudflared | Stop-Process -Force
# If the above fails with Access denied, run from elevated shell -- this
# IS the elevation-mismatch case the watchdog is designed to recover from.

# Wait up to 2 minutes; tail the log
Get-Content E:\code\remote-vscode-wsl-cloudflare\logs\health-check.log -Tail 20 -Wait
```

You should see a sequence like (real heal captured during testing on 2026-04-26):

```text
20:38:15  -- code-server killed inside WSL --
20:38:18 UNHEALTHY cloudflared=True origin=False public=True -- invoking auto-start.ps1 -NoLogonDelay
20:38:18   heal> === Dev Startup ===
20:38:19   heal> [DNS Ready] Attempt 1
20:38:19   heal> [WSL Ready] Attempt 1
20:38:21   heal> [Start Code Server] Attempt 1
20:38:22   heal> [WSL] Starting code-server...
20:38:26   heal> [WSL] code-server is LISTENING on 8081
20:38:26   heal> [HTTP Ready] Attempt 1
20:38:26   heal> [Tunnel Start] cloudflared alive + origin healthy -- skip
20:38:26   heal> READY -> https://dev.yourdomain.com
20:38:30 RECOVERED cloudflared=True origin=True public=True (heal exit=0)
```

Total downtime: 15 seconds in this run. The tunnel fast-path skip avoided needlessly restarting cloudflared.

## Logs

All four log streams live in one directory (`<repo>/logs/`) for easy correlation:

| Path | Written by | What's in it |
|---|---|---|
| `logs/startup.log` | `auto-start.ps1` (logon + heal-time) | Full PowerShell transcript of every bring-up |
| `logs/health-check.log` | `health-check.ps1` (every 2 min) | One line per probe; heal output prefixed with `heal>` |
| `logs/code-server.log` | mirrored from WSL `/tmp/code-server.log` | code-server stdout/stderr; refreshed every cycle |
| `logs/cloudflared.log` | `cloudflared` itself | Tunnel registration, edge connections, origin connect failures |
| `logs/failure-<ts>.txt` | `health-check.ps1` on UNHEALTHY | One file per failure: network adapters, DNS resolvers, routes, TCP reachability, cloudflared metrics, last 5 min of Windows event log |

`cloudflared.log` is enabled by default in the repo template ([windows/cloudflared-config.yml](../windows/cloudflared-config.yml)). The two relevant lines:

```yaml
loglevel: info
logfile: E:\code\remote-vscode-wsl-cloudflare\logs\cloudflared.log
```

If you're upgrading an existing deployment that did not have logging enabled, add those lines to `C:\Users\<you>\.cloudflared\config.yml` and restart cloudflared (`Stop-Process -Name cloudflared -Force` from elevated shell; the watchdog's next failure cycle will restart it).

### Log format

`health-check.log` records each probe with concrete values, not booleans -- so failures are diagnosable from the log alone. Every line also carries a compact cloudflared metrics suffix (`mx=...`) for trend analysis:

```text
2026-05-13T07:26:47 OK cloudflared=alive(PID=19208) origin=200 public=200 mx=reqs:35 errs:0 ha:3 proxyerr:0
2026-04-26T20:53:30 UNHEALTHY cloudflared=DEAD origin=conn-refused public=200 mx=down -- invoking auto-start.ps1 -NoLogonDelay
2026-04-26T20:53:42 RECOVERED cloudflared=alive(PID=12345) origin=200 public=200 mx=reqs:36 errs:0 ha:3 proxyerr:0 (heal exit=0)
```

The `mx=` fields come from cloudflared's Prometheus endpoint at `127.0.0.1:20241/metrics`:

| Field | Counter | Watch for |
|---|---|---|
| `reqs` | `cloudflared_tunnel_total_requests` | Cumulative; should only grow |
| `errs` | `cloudflared_tunnel_request_errors` | Origin-side errors; non-zero deltas precede `public=timeout` |
| `ha` | `cloudflared_tunnel_ha_connections` | Active edge connections; expect 3 (one per Cloudflare PoP) |
| `proxyerr` | `cloudflared_proxy_connect_streams_errors` | Proxy-layer connect failures; non-zero is concerning |
| `mx=down` | (endpoint unreachable) | cloudflared is dead |

Per-probe failure values map to causes:

| Value | What it means |
|---|---|
| `DEAD` | `cloudflared` process not found |
| `conn-refused` | Local origin (code-server) not listening on the port |
| `timeout` | Probe couldn't get a response within the timeout |
| `dns-fail` | Hostname couldn't be resolved |
| `tls-error` | TLS handshake or cert validation failed |
| `5xx` (e.g., `503`, `530`) | Upstream returned an error -- often Cloudflare can't reach origin |
| `ERR:<TypeName>` | Unexpected exception; check the .NET type for the actual cause |

### Failure snapshots

When `health-check.ps1` detects UNHEALTHY, before invoking heal it writes one file to `logs/failure-<yyyyMMdd-HHmmss>.txt` containing:

- All network adapters (Status, LinkSpeed, MediaConnectionState)
- DNS resolvers per interface
- Default route / gateway
- TCP reachability checks to `1.1.1.1:443`, `8.8.8.8:443`, `cloudflare.com:443`
- Full cloudflared metrics snapshot (key counters)
- Last 5 minutes of Windows Event Log entries from System (Warnings+Errors only, NVIDIA RTD3 noise filtered) plus DNS-Client, NetworkProfile, NCSI, WLAN-AutoConfig channels

This closes the diagnostic gap from RCA-008: the 2026-05-11 `public=timeout` events were undiagnosable because we had no network-state snapshot at the moment of failure. Files only land on UNHEALTHY events (rare). Prune manually if they pile up after sustained outages.

### Rotation

- `health-check.log` rotates at ~10MB to `health-check.log.1`. One generation kept. Done in `health-check.ps1`.
- `startup.log` rotates at ~10MB to `startup.log.1`. One generation kept. Done in `auto-start.ps1` before `Start-Transcript`.
- `code-server.log` is overwritten on each cycle (it's a mirror, not an append log).
- `cloudflared.log` rotates at ~50MB to `cloudflared.log.1`. Done in `health-check.ps1`. Higher threshold because rotation requires stopping cloudflared to release the Windows file handle (~2-5s tunnel blip); the heal-flow auto-restarts it on the next probe cycle. cloudflared has no built-in rotation on Windows.

## External heartbeat (dead-man's-switch)

The local watchdog cannot detect its own non-execution. If Task Scheduler is disabled, the laptop is asleep, the disk is full, or `health-check.ps1` itself crashes silently, you find out by opening the URL and seeing it dead.

`health-check.ps1` supports an optional outbound ping to [Healthchecks.io](https://healthchecks.io) (or any HTTP endpoint with the same `<url>` for OK and `<url>/fail` for failure semantics — Better Stack, Cronitor, a self-hosted endpoint, etc.). If the watchdog stops checking in, Healthchecks emails you.

**Setup (one-time):**

1. Sign up free at <https://healthchecks.io>.
2. Create a check. Period: 5 minutes. Grace: 1 minute. Name: `Dev Environment`. Copy the "Ping URL".
3. Edit `E:\code\auto-start.config.ps1`, set:

   ```powershell
   $HEALTHCHECK_URL = "https://hc-ping.com/<your-uuid>"
   ```

4. Next health-check cycle picks it up — no restart needed (the config is dot-sourced fresh every cycle).

**Behavior:**

- `OK` and `RECOVERED` cycles ping the bare URL → check shows as "up" with green dot.
- `STILL UNHEALTHY` cycles ping `<url>/fail` → check goes red immediately.
- Pings have a 5-second timeout and never affect the health-check result. A network blip to Healthchecks (which is the case you most want to alert on) silently fails the ping, and Healthchecks alerts you when no ping arrives in 5+ minutes.

Leave `$HEALTHCHECK_URL = $null` to disable. Existing deployments that never set the variable continue to work unchanged.

## Operator playbook for failures the watchdog can't recover

See the table at the bottom of [RELIABILITY.md](RELIABILITY.md). Common patterns:

- **`STILL UNHEALTHY` repeats indefinitely** with `cannot stop cloudflared ... likely elevated` in the heal output -- run `Stop-Process -Name cloudflared -Force` from an elevated PowerShell, then wait one cycle.
- **`STILL UNHEALTHY` repeats** with `wsl exited <N>` -- WSL is hung. Run `wsl --shutdown` once. Watchdog recovers on next cycle.
- **`STILL UNHEALTHY` with no heal output** -- the watchdog itself can't run. Check `Get-ScheduledTaskInfo -TaskName "Dev Environment Health Check"` for the last error code.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName "Dev Environment Health Check" -Confirm:$false
```
