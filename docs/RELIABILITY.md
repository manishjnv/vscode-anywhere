# Reliability: per-component failure modes and permanent solutions

For each layer in the stack, this document lists the realistic failure modes, the *permanent* fix (architectural), and what the watchdog (`health-check.ps1`) does about it when permanent fixes aren't possible.

The stack, top-to-bottom:

```
Browser  ->  Cloudflare edge  ->  cloudflared (Win)  ->  127.0.0.1:8081  ->  WSL2  ->  code-server  ->  /mnt/e/code
```

Each section follows the same shape:

- **Failure modes** — what actually breaks
- **Permanent solutions** — design changes that prevent the failure (one-time investment)
- **Detection** — how the watchdog notices when the failure does happen
- **Auto-recovery** — what the watchdog does about it

---

## 1. Cloudflare edge (DNS / Access / TLS termination)

This is the only component **not** running on the local machine. It is also the only one we cannot directly fix or restart.

### Failure modes

- **Cloudflare global outage.** Rare but not zero. All requests fail.
- **Cloudflare Access misconfiguration.** Policy deleted, wrong identity provider, expired Google OAuth credentials.
- **DNS record drift.** The CNAME pointing `dev.<domain>` at `<tunnel-uuid>.cfargotunnel.com` gets edited or deleted in the Cloudflare dashboard.
- **Cert expiration.** The wildcard cert Cloudflare auto-manages for the apex domain. Self-renewing on free tier; can fail if the domain validation method changes.
- **Hostname rate-limited / bot-challenged.** Cloudflare's bot-fight mode escalates the security level, surfacing a CAPTCHA before Access.

### Permanent solutions

- **Use a *named* tunnel** (we already do — `dev-tunnel`) so the credentials JSON is portable. Rebuilding the tunnel only requires `cloudflared tunnel route dns ...` to recreate the CNAME, not a new tunnel ID.
- **Back up `cert.pem` and `<UUID>.json`** out of `C:\Users\<you>\.cloudflared\` to a password manager / encrypted note. Without them, a laptop reimage means rebuilding the tunnel from scratch and updating the DNS record.
- **Pin the Access policy to a long session duration** (24h) so transient Cloudflare hiccups don't force a re-auth.
- **Subscribe to https://www.cloudflarestatus.com/** RSS feed for advance warning of edge outages.

### Detection

`Invoke-WebRequest https://$PUBLIC_HOST` from `health-check.ps1`. Catches edge outages, DNS drift, and Access misconfigurations via the same single probe.

### Auto-recovery

**None.** This component is outside our control. The watchdog logs the failure but does not retry indefinitely against a healthy-from-our-side stack -- if cloudflared is alive locally and the public URL is dead, Cloudflare itself is the culprit and our restart loops would be noise.

---

## 2. cloudflared (Windows host)

The `cloudflared` daemon maintains the outbound tunnel from the laptop to Cloudflare's edge. Single point of failure between local origin and the world.

### Failure modes

- **Process crash.** Most common cause: network blip during QUIC reconnection. Process exits non-zero.
- **Tunnel registration timeout.** Fresh launch hangs registering with Cloudflare's edge for >15 seconds (rate-limit, network slowness, or cloudflared client/edge version mismatch).
- **Stale credentials.** `<UUID>.json` deleted or moved; cloudflared exits immediately on launch.
- **Killed by Windows Defender / antivirus.** False-positive heuristic; rare but seen.
- **Auto-update reset.** Some installs include an auto-updater that bounces the process at unpredictable times.
- **Elevation mismatch on restart.** Documented in [RCA-002](RCA.md): a non-elevated re-run can't kill an elevated cloudflared. Now mitigated by idempotent fast-path skip.

### Permanent solutions

- **Idempotent restart logic.** Implemented in `Start-Tunnel` -- never kills a healthy cloudflared. See [RCA-002](RCA.md).
- **Watchdog catches crashes within 2 minutes.** See `health-check.ps1`. We accept up to ~2 minutes of unavailability rather than running a Windows service (which has its own failure modes).
- **Pin cloudflared to a known-good version.** Disable auto-update; bump manually after testing. (Track currently-installed version with `cloudflared --version`; bumps go in a CHANGELOG note in this repo.)
- **Add `cloudflared` to Windows Defender exclusions** if false positives become a pattern.

### Detection

`Test-PublicUrlHealthy` in `health-check.ps1`. If the URL fails, `auto-start.ps1 -NoLogonDelay` runs; its idempotent `Start-Tunnel` either fast-paths (no-op) or restarts cloudflared.

### Auto-recovery

`auto-start.ps1 -NoLogonDelay` invoked by the watchdog. The idempotent `Start-Tunnel`:

1. Checks if cloudflared is running AND public URL responds. If yes, skip.
2. Otherwise, kills any existing cloudflared (with elevation-mismatch error if applicable).
3. Starts a fresh cloudflared, polls public URL up to 30 seconds.
4. Retries up to 5 times if the first launch doesn't register cleanly.

Total recovery budget per heal cycle: ~2.5 minutes. If still failing after that, next watchdog cycle (2 min later) tries again.

---

## 3. Windows host: Task Scheduler, PowerShell, network stack

The orchestration substrate. Failures here mean the watchdog itself doesn't run.

### Failure modes

- **Task Scheduler task disabled / deleted.** User accident, group policy, or a Windows feature update sometimes resets scheduled tasks.
- **PowerShell execution policy tightened.** Some endpoint-management tools push a `Restricted` policy that prevents `auto-start.ps1` from running.
- **`E:` drive missing.** External drive disconnected, drive letter remapped, BitLocker not unlocked at boot.
- **Network adapter not initialized at logon.** Common on laptops resuming from sleep.
- **WSL update bricks WSL.** A Windows update silently bumps the WSL kernel; existing distros don't start.
- **Windows Sleep / Hibernate.** Tunnel and code-server both die when the laptop sleeps. Wake-from-sleep brings them back, but the tunnel needs a few seconds to re-register.

### Permanent solutions

- **Two scheduled tasks instead of one:**
  - "Dev Environment Startup" -- at logon, runs `auto-start.ps1`.
  - "Dev Environment Health Check" -- every 2 minutes, runs `health-check.ps1`.
  Loss of either is partial degradation, not total failure.
- **`-ExecutionPolicy Bypass` in the Task Scheduler arguments.** Already done; survives a `Restricted` group policy.
- **`-NoProfile` for both tasks.** Already done in `health-check.ps1`'s invocation of `auto-start.ps1`. Avoids a profile script breaking the run.
- **Start the task with "Run only when user is logged on" + "Run with highest privileges".** Required so cloudflared can bind to its config and survive elevation kills.
- **Put `E:\code\` on the C: drive** if you want resilience against E: drive issues. Not done here because the project tree is on E: by user choice.
- **Disable Windows Fast Startup** (`powercfg /h off`) -- the hybrid hibernate state doesn't always restart auto-start scripts cleanly.

### Detection

The watchdog cannot detect its own non-execution. External signal: open `https://dev.yourdomain.com` in a browser and see if it answers. The Task Scheduler "Last Run Result" column shows `0x0` for healthy runs.

### Auto-recovery

For Task Scheduler-level failures: not automatic. Operator must check Task Scheduler manually. Mitigation: set "If the task fails, restart every 1 minute, up to 3 attempts" on both tasks.

For sleep/wake: the watchdog firing 2 minutes after wake will detect the dead tunnel and heal it.

---

## 4. WSL2 (kernel + distro)

The Linux subsystem hosting code-server. Highest stateful complexity in the stack.

### Failure modes

- **Distro stopped.** WSL idle-shutdown after ~10 minutes of inactivity with no running processes; happens if code-server crashed and nothing else is keeping the distro awake.
- **WSL kernel hung.** `wsl -e ...` returns immediately or hangs forever. Usually after a Windows update bumped the kernel mid-session.
- **Wrong distro targeted.** Documented in [RCA-004](RCA.md). Hardcoded distro name doesn't match the deployed user.
- **`getpwnam` failure.** WSL user doesn't exist in the targeted distro.
- **Mount drift.** `/mnt/e/code` becomes unreadable because the E: drive went away; code-server starts but every file operation fails.
- **systemd init issues.** Distros with systemd enabled (`/etc/wsl.conf` `systemd=true`) sometimes hang startup.

### Permanent solutions

- **Explicit `$WSL_DISTRO` in config**, with `$LASTEXITCODE` checks via `Invoke-WSL` helper. See [RCA-004](RCA.md).
- **Document the deployment in memory** (`memory/project_wsl_distros.md`) so future sessions don't re-derive which distro is which.
- **Avoid `wsl --shutdown` in heal flows** unless absolutely necessary -- it kills *all* distros and dumps unsaved state from anything else the user is running.
- **Pin the WSL kernel via `.wslconfig`** if a Windows update bricks WSL repeatedly. Lower-priority because it's rare.

### Detection

Indirect: if WSL is hung or the distro is wrong, `Test-PublicUrlHealthy` will fail (because code-server can't serve). The watchdog then runs `auto-start.ps1`, whose `Wait-WSL` will fail loudly with the actual `$LASTEXITCODE` from WSL.

### Auto-recovery

`auto-start.ps1`'s `Wait-WSL` retries `wsl ... echo ready` 5 times with 3-second backoff. If WSL is genuinely hung, the operator must intervene -- the watchdog deliberately does not run `wsl --shutdown` (too destructive). The error in `health-check.log` will say `wsl exited <code> running: echo ready`, which is enough to diagnose manually.

---

## 5. code-server (inside WSL)

The actual web IDE. Bug surface: code-server itself, the extension host, the underlying Node.js runtime.

### Failure modes

- **Crash on extension load.** Misbehaving Open VSX extension; usually surfaces with "Extension Host terminated unexpectedly" but can also kill the whole process.
- **Port already in use.** Another process bound to 8081 between auto-start runs.
- **Out-of-memory.** Long-running session with many extensions can exhaust WSL's memory cap (default ~50% of host RAM).
- **Marketplace gone.** Open VSX outage; `EXTENSIONS_GALLERY` URL unreachable. Search and install break, but running extensions keep working.
- **Settings sync corruption.** `~/.local/share/code-server/User/` ends up in a bad state; settings reset on every reload.

### Permanent solutions

- **Idempotent `Start-CodeServer`.** Implemented. Won't restart code-server if 8081 is already healthy. Won't drop active sessions for no reason. See [RCA-002](RCA.md).
- **`fuser -k $PORT/tcp` before launch** in `start-code-server.sh` ensures stale processes don't block re-bind.
- **`EXTENSIONS_GALLERY` exported in `start-code-server.sh`.** Persists across restarts.
- **Cap WSL memory** in `~/.wslconfig` if OOM becomes a recurring pattern. Default is generous; only revisit if it bites.
- **Pin code-server version.** Currently uses `curl ... | sh` (latest). Pin to a tested version after a known-good run; bump deliberately. (Tracked in this repo's CHANGELOG when adopted.)

### Detection

`Test-LocalHTTP` (probes `http://127.0.0.1:8081`) inside `auto-start.ps1`. The watchdog itself probes only the public URL -- if code-server is down, the public URL fails, the heal runs, `Start-CodeServer` notices the local probe is failing, restarts the WSL launcher.

### Auto-recovery

`Start-CodeServer` invokes `~/start-code-server.sh` inside WSL, which kills any stale port holder and relaunches code-server detached via `setsid`. Up to 5 retries with 3-second backoff. Active in-browser sessions are dropped; users see a "Reconnecting..." spinner until the new instance accepts connections (typically 5-10 seconds).

---

## What the watchdog deliberately does NOT do

- **No metrics export, no alerting integrations, no Slack notifications.** Local-only deployment; opening the URL in a browser and seeing it answer is the operator's "alert".
- **No restart-counter circuit breaker.** If something genuinely cannot heal, the every-2-min retry is cheap and harmless; an operator will notice when the URL stays down.
- **No `wsl --shutdown` in heal flows.** Too destructive (kills other distros). If WSL is hung, surface the error and let the operator decide.
- **No automatic cloudflared / code-server upgrades.** Both are version-pinned by deliberate choice (or will be, once we adopt that). Auto-upgrade is a class of failure unto itself.

## Operator playbook when the watchdog can't recover

In `E:\code\remote-vscode-wsl-cloudflare\logs\health-check.log`, look for the most recent `STILL UNHEALTHY` entry and the heal output that preceded it:

| Heal output contains | Likely cause | Manual fix |
|---|---|---|
| `wsl exited <N> running: echo ready` | WSL hung or distro broken | `wsl --shutdown`, then `wsl -d <your-distro> -e echo ready` |
| `cannot stop cloudflared (PID ...) -- likely elevated` | Stale elevated cloudflared | Run `health-check.ps1` once from elevated shell, or `Stop-Process -Name cloudflared -Force` from an Admin PowerShell |
| `cloudflared exited with code <N>` | Bad credentials, missing config | Check `C:\Users\<you>\.cloudflared\config.yml`; verify `<UUID>.json` exists |
| `public URL ... not responding within 30s` | Cloudflare edge or DNS issue | Check https://www.cloudflarestatus.com/; verify CNAME in Cloudflare dashboard |
| Repeated `OK` then sudden block of `UNHEALTHY` | Cloudflare Access policy change, or cert renewal in progress | Check Zero Trust audit logs |
