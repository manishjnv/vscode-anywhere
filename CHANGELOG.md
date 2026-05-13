# Changelog

All notable changes to the Remote VS Code stack, newest first. Each entry pairs *what changed* with *why* so a future operator (or future-you) can reconstruct the reasoning without re-reading the entire git history.

Cross-references:

- **Bug post-mortems** live in [docs/RCA.md](docs/RCA.md) (numbered RCA-001 onward).
- **Per-component failure modes** in [docs/RELIABILITY.md](docs/RELIABILITY.md).
- **Version baselines** in [docs/VERSIONS.md](docs/VERSIONS.md).
- **Watchdog mechanics** in [docs/MONITORING.md](docs/MONITORING.md).

---

## 2026-05-13 — Reliability hardening + forensic capture after 48-hour review

**Commits:** [`2a6074c`](https://github.com/manishjnv/vscode-anywhere/commit/2a6074c), [`cf3613e`](https://github.com/manishjnv/vscode-anywhere/commit/cf3613e), [`11ec53c`](https://github.com/manishjnv/vscode-anywhere/commit/11ec53c)
**Stack state at end of session:** code-server 4.116.0, cloudflared 2025.8.1 (PID 19208 throughout), origin=200, public=200, Healthchecks.io check armed, watchdog cadence 2 min.

### Context

A "find failures in the last 48 hours" review surfaced **two transient `public=timeout` events on 2026-05-11 around 03:00 IST** that the existing monitoring couldn't diagnose. Local stack was healthy throughout (cloudflared alive, origin returning 200); only the Cloudflare-edge → origin path failed briefly. The watchdog correctly avoided a destructive restart but had **no forensic data** to identify the root cause. Most plausibly an ISP / home-router event at 03:00 IST — many ISP-provided routers default to a nightly scheduled reboot.

That investigation triggered a deep review of every component in the stack and produced this batch of changes: **close the diagnostic gap** so the next similar event WILL be solvable, and **harden** against the failure modes the review surfaced.

### Bug fixes (with RCA entries)

| RCA | Symptom | Root cause | Fix |
|---|---|---|---|
| [RCA-008](docs/RCA.md#rca-008) | `public=timeout` events undiagnosable in hindsight | cloudflared's stdout died with the elevated `Start-Process` console; no tunnel-side log persisted | Added `loglevel: info` + `logfile:` to `cloudflared` config; repo template now enables by default |
| [RCA-009](docs/RCA.md#rca-009) | cloudflared ingress used `http://localhost:8081`, relied on `::1` fast-RST → IPv4 fallback | Windows returns BOTH `::1` (AAAA) and `127.0.0.1` (A) for `localhost` regardless of adapter IPv6 toggles; happy-eyeballs fallback is fragile | Changed live + template ingress to `http://127.0.0.1:8081` |
| [RCA-010](docs/RCA.md#rca-010) | PowerShell console window flashed every 2 min on the desktop | `powershell -WindowStyle Hidden` is parsed *after* `conhost.exe` shows the window — ~100 ms flash before Hide directive applies | Added `windows/run-hidden.vbs` shim (called via `wscript.exe`), updated scheduled task action |

### Diagnostic capture (the new forensic layer)

This is the single biggest change of the session — every signal needed to diagnose a future `public=timeout` event is now captured automatically:

1. **Per-cycle metrics suffix** on every `health-check.log` line:
   ```
   OK cloudflared=alive(PID=19208) origin=200 public=200 mx=reqs:35 errs:0 ha:3 proxyerr:0
   ```
   Scraped from cloudflared's Prometheus endpoint at `127.0.0.1:20241/metrics`. Counters:
   - `reqs` — `cloudflared_tunnel_total_requests` (cumulative)
   - `errs` — `cloudflared_tunnel_request_errors` (**non-zero deltas precede user-visible failures**)
   - `ha`   — `cloudflared_tunnel_ha_connections` (active edge PoPs; expect 3)
   - `proxyerr` — `cloudflared_proxy_connect_streams_errors`
   - `mx=down` — endpoint unreachable (cloudflared dead)

2. **Failure-time forensic snapshot.** On every UNHEALTHY detection (before invoking heal), `health-check.ps1` writes one file to `logs/failure-<yyyyMMdd-HHmmss>.txt` containing:
   - All network adapters with Status / LinkSpeed / MediaConnectionState
   - DNS resolvers per interface
   - Default route + gateway
   - TCP reachability to `1.1.1.1:443`, `8.8.8.8:443`, `cloudflare.com:443`
   - Filtered cloudflared metrics (high-signal counters only)
   - Last 5 minutes of Windows Event Log: System (Warn+Error only, NVIDIA RTD3 noise filtered), DNS-Client, NetworkProfile, NCSI, WLAN-AutoConfig channels
   - Distinguishes "channel had zero events" from "channel doesn't exist" so the file never lies about coverage
   - ~2-5 KB per snapshot, only lands on rare UNHEALTHY events

3. **External dead-man's-switch.** `Send-Heartbeat` helper in `health-check.ps1` pings a configurable URL on every cycle. Pings `<url>/fail` on STILL UNHEALTHY. Configured to <https://hc-ping.com/8dcb0467-7cb2-4fb9-85fc-2649d4de2bd8> (5-min period, 1-min grace, email alert to `manishjnvk@gmail.com`). Closes the one class of failure the local watchdog cannot self-detect: **its own non-execution**.

4. **`cloudflared.log`** persists cloudflared's own perspective continuously — edge connect/disconnect, QUIC negotiation, origin connect failures, registration churn. Rotation managed by the watchdog.

### Hardening against identified failure modes

| Change | Where | Why |
|---|---|---|
| `originRequest: { keepAliveTimeout: 30s, connectTimeout: 10s }` | `.cloudflared/config.yml` (live + template) | Stale pooled TCP connections after sleep/wake drop within 30 s instead of being held indefinitely. Caps origin-connect at 10 s so a hung WSL can't stall edge requests for cloudflared's 30 s default. |
| `w32tm /resync /force` at top of `auto-start.ps1` | [windows/auto-start.ps1](windows/auto-start.ps1) | Long sleep / battery drain causes clock drift; first TLS handshake then fails with cert-not-yet-valid until Windows time sync catches up. Eliminates the symptom. |
| `Wait-Network` swapped: `Resolve-DnsName 1.1.1.1` → `Test-NetConnection 1.1.1.1 -Port 443` | [windows/auto-start.ps1](windows/auto-start.ps1) | PTR lookup observed timing out for 16 s per attempt during the 2026-05-11 WAN flap → 160 s of dead heal-script time across 10 retries. TCP-connect fails in ~1 s. Heal log now says `[Network Ready]` instead of `[DNS Ready]`. |
| `[wsl2] networkingMode=nat` pinned | `C:\Users\manis\.wslconfig` | Defensive against a future Windows update flipping the default to `mirrored`, which changes localhost-forwarding semantics and would break the IPv4 → WSL assumption baked into the whole stack. Activated via `wsl --shutdown` in this session. |
| `extensions.autoUpdate=false`, `extensions.autoCheckUpdates=false` | `~/.local/share/code-server/User/settings.json` (inside WSL) | Prevents Open VSX from silently bumping extensions into a broken state mid-session. Bump deliberately from the Extensions sidebar UI. |
| Log rotation for `startup.log` (10 MB) | [windows/auto-start.ps1](windows/auto-start.ps1) | Was append-only via `Start-Transcript`; ~800 KB after 4 months with no upper bound. Now rotates with a single `.1` archive. |
| Log rotation for `cloudflared.log` (50 MB) | [windows/health-check.ps1](windows/health-check.ps1) | cloudflared has no built-in rotation on Windows. Threshold higher than other logs because rotation requires stopping the daemon to release the file handle (~2-5 s tunnel blip); heal-flow auto-restarts on the next probe. |

### Verified (no change needed)

| Item | Finding |
|---|---|
| Both scheduled tasks have `MultipleInstances=IgnoreNew` | Already correct. Design intent (no concurrent heals) matches deployed state. |
| IPv6 disabled assumption | Only Wi-Fi adapter has IPv6 disabled; Ethernet and WSL vEthernet still have it enabled. No system-wide kill switch in registry. `localhost` returns both A and AAAA records regardless. See RCA-009. |

### New files

| File | Purpose |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | This file |
| [windows/run-hidden.vbs](windows/run-hidden.vbs) | Invisible VBScript launcher shim — `WScript.Shell.Run powershell..., 0, False` |
| [docs/VERSIONS.md](docs/VERSIONS.md) | Known-good version baseline (code-server 4.116.0, cloudflared 2025.8.1, WSL 2.7.3.0, Win 11 Pro 26200.8246). Bump log convention established. |

### Files edited (with one-line rationale)

| File | Change |
|---|---|
| [windows/health-check.ps1](windows/health-check.ps1) | `Send-Heartbeat`, `Get-CloudflaredMetricsSummary`, `Capture-FailureSnapshot`, `Invoke-CloudflaredLogRotation` added; metrics suffix appended to every OK/UNHEALTHY/RECOVERED line; snapshot fires once on UNHEALTHY before heal |
| [windows/auto-start.ps1](windows/auto-start.ps1) | `w32tm /resync` at top; `startup.log` rotation before `Start-Transcript`; `Wait-Network` uses TCP-connect probe |
| [windows/auto-start.config.example.ps1](windows/auto-start.config.example.ps1) | `$HEALTHCHECK_URL` template stanza (defaults to `$null`) |
| [windows/cloudflared-config.yml](windows/cloudflared-config.yml) | Logging enabled by default; `originRequest` block; comment block updated |
| [docs/RCA.md](docs/RCA.md) | RCA-008, RCA-009, RCA-010 added (newest first per existing convention) |
| [docs/MONITORING.md](docs/MONITORING.md) | Install snippet uses `wscript.exe` + VBS shim; `failure-<ts>.txt` log type documented; `mx=` field reference table; rotation table updated; new "External heartbeat" and "Failure snapshots" sections |

### Files edited outside the repo (system state)

These are part of the deployment but `.gitignored` or live in `%USERPROFILE%`. Documented here because future-you will need to know they were touched.

| Path | Change |
|---|---|
| `C:\Users\manis\.cloudflared\config.yml` | Added `loglevel: info` + `logfile:`; changed `service: http://localhost:8081` → `http://127.0.0.1:8081`; added per-rule `originRequest` block |
| `C:\Users\manis\.wslconfig` | Added `networkingMode=nat` with explanatory comment |
| `E:\code\auto-start.config.ps1` | Added `$HEALTHCHECK_URL = "https://hc-ping.com/8dcb0467-7cb2-4fb9-85fc-2649d4de2bd8"` |
| `~/.local/share/code-server/User/settings.json` (inside WSL) | Added `extensions.autoUpdate: false`, `extensions.autoCheckUpdates: false` |
| Scheduled task `Dev Environment Health Check` action | Changed from `powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File health-check.ps1` to `wscript.exe "run-hidden.vbs" "health-check.ps1"` |

### End-to-end verifications captured this session

- **Heal-flow integration test.** User ran `wsl --shutdown` mid-session. Watchdog detected `origin=no-route` at 07:20:18, healed via `Start-CodeServer` (tunnel skip path because cloudflared was untouched), RECOVERED at 07:20:44. **Total downtime: 26 s.** Heal log now showed `[Network Ready]` confirming the lighter probe ran on attempt 1.
- **Healthchecks.io integration.** Dashboard showed `new → up` transition; 4 pings within 3 min (one PS 7 sanity test + three PS 5.1 scheduled-task fires).
- **cloudflared restart resilience.** Daemon restarted twice during this session (once for logging-enable, once for `originRequest`+`127.0.0.1` change). Both restarts produced normal QUIC connection teardown noise and immediate re-registration to PoPs `bom11`, `blr03`, `bom08`. Tunnel availability blip ≤ 5 s each time.
- **Failure-snapshot function isolation test.** Invoked `Capture-FailureSnapshot` directly with a synthetic trigger; 2.4 KB file landed with all sections populated correctly, NVIDIA RTD3 noise filtered out, "zero events" message distinguishes from "channel missing".

### Operator follow-up (only the user can do these)

- [ ] **Check home router admin panel** for a nightly scheduled-reboot setting (default ~3 AM on many TP-Link / Asus / ISP-provided routers). Most plausible root cause of the 2026-05-11 events. Disable it or move it to a time you don't use code-server.
- [ ] **Back up** `C:\Users\manis\.cloudflared\cert.pem` and `C:\Users\manis\.cloudflared\be4eca71-7e76-435e-b00d-c4d172881ed0.json` to a password manager / encrypted note. Documented in RELIABILITY.md as "recommended"; never actually tested. Without these files, a laptop reimage means rebuilding the tunnel from scratch and recreating the DNS CNAME.
- [ ] **(Optional)** Add a second Healthchecks.io notification channel (Telegram, Slack, SMS) as backup for email — useful when email is the very thing that's broken.

### Skipped from the deep-review recommendations (with reasoning)

| Item | Why skipped |
|---|---|
| Content-aware origin probe (body check, not just status) | Over-engineered for this stack; the rare failure mode (HTTP server alive but extension host hung) doesn't justify the complexity |
| VBS engine deprecation fallback | Premature — Microsoft has announced but not actually pulled VBS. Will revisit when there's a concrete date |
| Daily log-freshness sanity check | Redundant with Healthchecks.io heartbeat, which catches the same failure mode (watchdog stopped writing) faster |

---

## 2026-04-26 — Initial production rewrite (idempotent auto-start + watchdog)

**Commit:** [`6dca327`](https://github.com/manishjnv/vscode-anywhere/commit/6dca327)

Replaced the original blind-kill-and-restart logon script with idempotent stage-by-stage bring-up; added the watchdog task ("Dev Environment Health Check") that probes every 2 minutes and invokes `auto-start.ps1 -NoLogonDelay` only when unhealthy. Captured 7 RCAs ([RCA-001](docs/RCA.md#rca-001) through [RCA-007](docs/RCA.md#rca-007)) from the bring-up debugging sessions.

Key architectural decisions established that day, still in force:

- Multi-signal health model (`cloudflared` process + local `127.0.0.1:8081` + public URL, ALL three required for "healthy") — see [RCA-007](docs/RCA.md#rca-007)
- Idempotent fast-path skip in every "ensure X is running" function — see [RCA-002](docs/RCA.md#rca-002)
- ASCII-only `.ps1` files (Windows PowerShell 5.1 parses UTF-8-without-BOM as CP-1252) — see [RCA-003](docs/RCA.md#rca-003)
- Explicit `$LASTEXITCODE` checks via `Invoke-WSL` helper after every native command — see [RCA-004](docs/RCA.md#rca-004)
- Follow redirects in `Test-PublicTunnel` because PS 5.1 returns `$null` `.Response` on redirect-policy violations — see [RCA-005](docs/RCA.md#rca-005)
- Poll-with-deadline instead of fixed-sleep-then-check for any "wait for X to come up" — see [RCA-006](docs/RCA.md#rca-006)

Documentation skeleton (`SETUP.md`, `MONITORING.md`, `RELIABILITY.md`, `SECURITY.md`, `TROUBLESHOOTING.md`, `ARCHITECTURE.md`, `FAQ.md`, `RCA.md`) authored the same day.

---

## 2026-04-25 — Mermaid architecture diagram in README

**Commit:** [`d5e5807`](https://github.com/manishjnv/vscode-anywhere/commit/d5e5807)

---

## 2026-04-23 — Initial public commit

**Commit:** [`9a5c81d`](https://github.com/manishjnv/vscode-anywhere/commit/9a5c81d)

First version of the remote-VS-Code-via-WSL-and-Cloudflare stack. Logon-time PowerShell launcher; manually-configured cloudflared tunnel; code-server inside WSL fronted by Cloudflare Access (Google SSO).
