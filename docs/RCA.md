# Root Cause Analysis Log

Each entry: symptom observed, root cause, fix landed, prevention so the same class of bug doesn't recur. Newest first.

---

## RCA-010: PowerShell health-check task flashed a console window every 2 minutes (2026-05-13)

**Symptom:** A PowerShell console window briefly appeared and disappeared every ~2 minutes on the desktop. Visible long enough to notice, too brief to interact with. Cause traced to the `Dev Environment Health Check` scheduled task firing on its 2-minute trigger.

**Root cause:** task action was `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ...`. The `-WindowStyle Hidden` argument is *parsed* by PowerShell **after** `conhost.exe` has already created and shown the console window for the process. The Hide directive then applies, but only after a ~50-200 ms flash. This is documented PowerShell-on-Windows behavior, not a misconfiguration -- `powershell.exe -WindowStyle Hidden` cannot suppress the initial flash because the window creation precedes argument parsing.

**Fix:**

- Added [windows/run-hidden.vbs](../windows/run-hidden.vbs) -- a small VBScript shim that calls `WScript.Shell.Run "powershell ...", 0, False`. `intWindowStyle = 0` means "no window at all", and `wscript.exe` is a windowless host to begin with, so nothing flashes.
- Updated the task action to `wscript.exe "...\run-hidden.vbs" "...\health-check.ps1"`. Verified the next two cycles ran silently with exit code 0 and continued writing `OK` entries to [logs/health-check.log](../logs/health-check.log).
- Updated [docs/MONITORING.md](MONITORING.md) install snippet so future deployments use the shim from the start.

**Prevention:** any scheduled task running a PowerShell script on a short interval (anything sub-hourly) must use the `wscript.exe + run-hidden.vbs` pattern, never raw `powershell -WindowStyle Hidden`. The latter looks correct, passes a code review, and *almost* works -- it's exactly the kind of paper-cut that gets ignored because each flash is too brief to debug in isolation. Codified in MONITORING.md alongside the install steps.

---

## RCA-009: cloudflared ingress used `localhost`, relying on IPv6-refused-then-IPv4 fallback (2026-05-13)

**Symptom:** Live `C:\Users\<user>\.cloudflared\config.yml` had `service: http://localhost:8081` while the repo's `auto-start.ps1` deliberately used `http://127.0.0.1:8081` everywhere. Visible only as a comment-thread observation -- the tunnel was working end-to-end. But it surfaced during investigation of the 2026-05-11 `public=timeout` events as a candidate contributor.

**Root cause:** Windows DNS Client returns BOTH records for `localhost`:

```text
localhost  AAAA  ::1
localhost  A     127.0.0.1
```

This happens even when IPv6 is disabled on individual adapters (Wi-Fi in this case) -- because the host's loopback resolution is independent of adapter bindings, and there is no `DisabledComponents` system-wide IPv6 kill switch. The `hosts` file's `::1 localhost` entry is commented out by default but Windows DNS Client returns the AAAA record anyway from its internal resolver.

WSL2's localhost-forwarding is IPv4-only. So a TCP connect to `[::1]:8081` gets an immediate TCP RST from the Windows network stack ("actively refused"). HTTP clients implementing happy-eyeballs (cloudflared's Go runtime, PowerShell's `Invoke-WebRequest`) transparently retry the A record (`127.0.0.1`) within ~1 ms and succeed.

It worked, but on a fragile assumption: that the failure mode on `::1:8081` is always *fast TCP RST*, not *silent drop* or *timeout*. If anything (Windows firewall rule change, code-server later binding to `::1`, Windows update touching the loopback stack) flips that, every cloudflared origin connect picks up multi-second latency on the IPv6 attempt -- which would manifest as `public=timeout` from the watchdog's perspective even though everything is "alive". This is the same family as RCA-007: a probe answer changing meaning depending on something invisible.

**Fix:** edited `C:\Users\manis\.cloudflared\config.yml` to use `service: http://127.0.0.1:8081`. Restarted cloudflared (PID rolled from 3284 → 10800). Both probes returned 200 immediately. The repo template at [windows/cloudflared-config.yml:32](../windows/cloudflared-config.yml#L32) already used `127.0.0.1`, so live and template are now aligned. Verified with `Resolve-DnsName localhost` (still returns both records, as expected) and `Invoke-WebRequest http://[::1]:8081` (still actively refused, as expected) -- the fix removes the dependency on the fallback, it doesn't change the underlying OS behavior.

**Prevention:**

- Stack-wide convention: all loopback URLs in this stack use the literal `127.0.0.1`, never `localhost`. Applies to cloudflared ingress, PowerShell probes, code-server listen address documentation, and any future component.
- The comment block at [windows/auto-start.ps1:27-29](../windows/auto-start.ps1#L27-L29) already documents this for the PowerShell side. Mirror that rationale into the cloudflared template comments next time the file is touched so a future operator doesn't "fix" it back to `localhost` thinking it's more idiomatic.
- "IPv6 is disabled" is rarely binary on Windows. Adapter-level binding toggles do not disable loopback IPv6 resolution. Verify with `Resolve-DnsName localhost` before assuming an IPv6 codepath is dead.

---

## RCA-008: `public=timeout` events on 2026-05-11 had no cloudflared-side log to diagnose against (2026-05-13)

**Symptom:** Two UNHEALTHY watchdog events in the last 48 hours, both 2026-05-11:

```text
03:00:23  UNHEALTHY cloudflared=alive(PID=23328) origin=200 public=timeout
03:01:59  STILL UNHEALTHY ...                                public=timeout
03:10:22  UNHEALTHY ...                                      public=timeout
03:10:29  RECOVERED  ...                                     public=200
```

Local stack was healthy throughout -- the cloudflared daemon was alive, code-server on `:8081` returned 200 locally, only the public URL through the Cloudflare edge timed out. The heal-flow during event #1 also surfaced 4 consecutive `Resolve-DnsName 1.1.1.1` timeouts, suggesting a simultaneous WAN flap. But the root cause -- "was this Cloudflare edge, our WAN, or origin TCP wobble?" -- could not be proven from the data captured.

**Root cause:** monitoring captured "what failed at the local-probe layer" via `health-check.log`, but cloudflared's own logs (which would show edge disconnects, connection retries, registration churn, origin connect failures) were not being persisted. cloudflared was started by `auto-start.ps1`'s `Start-Process cloudflared` with no `--logfile` flag, and the config file at `C:\Users\<user>\.cloudflared\config.yml` did not enable file logging. The daemon's stdout went to the transient console of the elevated Start-Process invocation and was lost. So when public=timeout fired, the watchdog log proved *that* the public path was unreachable from this host, but had no paired tunnel-side log to disambiguate edge-vs-origin-vs-WAN.

**Fix:**

- Added `loglevel: info` + `logfile: E:\code\remote-vscode-wsl-cloudflare\logs\cloudflared.log` to live `C:\Users\manis\.cloudflared\config.yml`. Updated repo template [windows/cloudflared-config.yml](../windows/cloudflared-config.yml) so logging is enabled by default for future setups (it was previously a commented-out optional block).
- Restarted cloudflared; verified the log now captures `Starting tunnel`, version, connector ID, protocol selection (`quic`), per-connection registration at Cloudflare PoPs (`blr03`, `bom12`), and tear-down events on restart.
- Confirmed end-to-end signal: stopped previous PID, restarted, observed the QUIC connections cancel and re-register in the new log -- so the next genuine edge wobble will produce a paired entry.

**Prevention:**

- Any daemon whose health we monitor must persist its own logs to a known file location. The watchdog's `cloudflared=alive` boolean is necessary but not sufficient -- "alive" tells you the process exists, not that its tunnels are healthy.
- For monitored-component health checks, the rule "probe must verify the layer it claims to verify" (RCA-007) has a sibling rule: "the monitored component must log enough of its own internal state to diagnose a failure that's invisible from the probe layer". A binary alive/dead probe + a verbose component log is the minimum diagnostic surface.
- Codified the cloudflared logfile path in the repo template, so a future operator setting up from scratch gets logging by default rather than discovering its absence during an incident.
- No code change was needed for the actual `public=timeout` failure mode -- the watchdog correctly identified that local services were healthy and skipped a destructive restart (a local restart cannot fix a Cloudflare-edge or WAN problem). The fix is purely diagnostic capture for next time.

---

## RCA-007: Watchdog probe was checking the wrong layer; dead origin appeared healthy (2026-04-26)

**Symptom:** During the first heal-flow demo, manually killed `cloudflared` (and later, code-server inside WSL). The public URL `https://dev.yourdomain.com` continued to return 200 for several minutes after both were dead. The watchdog dutifully logged `OK` every 2 minutes while the IDE was completely unreachable to a real user.

**Root cause:** Cloudflare Access serves its **login page from Cloudflare's edge** without ever contacting the origin. An unauthenticated `Invoke-WebRequest` hits `dev.yourdomain.com`, gets redirected to `<team>.cloudflareaccess.com/cdn-cgi/access/login/...`, and receives a 200 (the HTML login page) -- regardless of whether the tunnel daemon, the local origin, or even the entire host is alive. The probe was effectively measuring "is Cloudflare's login service up" which is a property of Cloudflare's global infrastructure, not of our stack.

This applies to both `health-check.ps1`'s heal trigger AND `auto-start.ps1`'s `Start-Tunnel` fast-path skip, both of which used `Test-PublicTunnel`. So `auto-start.ps1` would also falsely skip restarting cloudflared if the daemon had died but Access was still serving login pages.

**Fix:** moved both scripts to a multi-signal health model. ALL three must pass for "healthy":

1. `Get-Process cloudflared` returns a process (daemon alive on this host)
2. `http://127.0.0.1:$PORT` returns 2xx-4xx (local origin alive)
3. `https://$PUBLIC_HOST` returns 2xx-4xx (DNS + edge + Access serving)

`health-check.ps1` runs all three on every cycle and logs the per-signal status:

```text
2026-04-26T20:38:18 UNHEALTHY cloudflared=True origin=False public=True
2026-04-26T20:38:30 RECOVERED cloudflared=True origin=True public=True (heal exit=0)
```

`auto-start.ps1`'s `Start-Tunnel` fast-path now requires `(cloudflared alive) AND (local origin alive)` instead of `(cloudflared alive) AND (public URL responds)`. The post-launch verification was simplified to "process didn't exit during the 8-second settle window" -- we can't reliably verify end-to-end registration without a service-token-authenticated probe, so we trust the next watchdog cycle to catch a registration that silently failed.

End-to-end test on the same day:

```text
20:38:15  code-server killed
20:38:18  UNHEALTHY cloudflared=True origin=False public=True  -- detected
20:38:18-26  heal: invoked auto-start.ps1; restarted code-server only (tunnel skip-path)
20:38:30  RECOVERED -- 15-second total downtime
```

**Prevention:**
- Health probes must verify the layer they claim to verify. Probing a CDN edge tells you about the CDN, not your origin.
- For *any* probe-based health check, ask: "what would still be true if every component below this layer were dead?" If the answer includes the probe response, the probe is wrong.
- Long-term improvement option (not adopted): create a Cloudflare Access service token for the watchdog, send authenticated requests, and read the actual code-server response. Service tokens bypass the SSO redirect and get forwarded to origin -- a 200 from THAT request is genuine end-to-end. Deferred because (a) it requires Zero Trust dashboard config not currently in scope, (b) the multi-signal local probe gets us 95% of the value with zero new credentials, and (c) the public URL signal still catches Cloudflare-side breakage that local probes can't see.
- Saved as a memory entry so future sessions don't re-derive the same fix.

---

## RCA-006: Watchdog single-shot probe raced cloudflared cold-start (2026-04-26)

**Symptom:** First version of `Start-Tunnel` did `Start-Process cloudflared`, slept 8 seconds, then probed once. On a cold launch the tunnel needed 10-15 seconds to register with Cloudflare's edge, so the single probe returned "no" and the script moved to the next retry attempt -- which killed the still-registering cloudflared and restarted it. Tunnel never got past the registration handshake.

**Root cause:** sleep-then-probe is the wrong pattern when the underlying operation has variable latency. We were *measuring against an arbitrary deadline* rather than *waiting for the actual signal*.

**Fix:** [windows/auto-start.ps1](../windows/auto-start.ps1) `Start-Tunnel` now polls `Test-PublicTunnel` every 2 seconds for up to 30 seconds inside each retry attempt. Returns as soon as the tunnel is healthy; throws (triggering the outer `Retry`) only if 30 seconds elapse without success. Total budget: 5 attempts * 30 seconds = 2.5 minutes.

**Prevention:** for any "wait for X to come up" pattern, prefer poll-with-deadline over fixed-sleep-then-check. The deadline only fires when something is genuinely wrong; the fast common case still completes quickly.

---

## RCA-005: PS 5.1 + `-MaximumRedirection 0` returns null `.Response` on redirect (2026-04-26)

**Symptom:** `Test-PublicTunnel` worked when tested manually from PowerShell 7+ (returned `True` on Cloudflare Access's 302 redirect) but always returned `False` when invoked via `powershell` (5.1) by Task Scheduler. Result: the fast-path "tunnel already healthy, skip" never fired -- every script run needlessly killed and restarted cloudflared.

**Root cause:** Windows PowerShell 5.1's `Invoke-WebRequest` with `-MaximumRedirection 0` throws `System.InvalidOperationException` ("Operation is not valid due to the current state of the object.") with `$_.Exception.Response` set to **null** when it hits a 3xx. PS 7+ exposes the redirect via `.Response.StatusCode` so a `catch` block can recover the status code. Same code, two completely different control flows.

**Fix:** [windows/auto-start.ps1](../windows/auto-start.ps1) `Test-PublicTunnel` now follows redirects (default `-MaximumRedirection 5`) and accepts any 200-499 status. The Cloudflare Access redirect chain ends at `<team>.cloudflareaccess.com/cdn-cgi/access/login/...` returning 200 -- positive proof that tunnel + Access are both healthy end-to-end. Also forces `[Net.SecurityProtocolType]::Tls12` defensively because PS 5.1's TLS default depends on the .NET runtime.

**Prevention:** `.ps1` files that target Windows PowerShell 5.1 (the default `powershell.exe`, what Task Scheduler invokes) MUST be tested under PS 5.1 explicitly via `powershell -NoProfile -Command { ... }`. PS 7+ behavior is not a substitute -- the deltas are real and silent. Captured as a memory rule for future sessions.

---

## RCA-004: Wrong WSL distro hardcoded; `$LASTEXITCODE` swallowed the error (2026-04-26)

**Symptom:** During the first end-to-end test of the rewritten launcher, transcript showed `<3>WSL (347 - Relay) ERROR: CreateProcessParseCommon:988: getpwnam(admin) failed 0` -- and yet `[WSL Ready] Attempt 1` reported success. Subsequent stages happened to pass because code-server was already running from a prior session, masking the broken WSL invocation.

**Root cause:** Two compounding bugs.
1. `auto-start.config.example.ps1` defaulted `$WSL_DISTRO = "Ubuntu"` based on assumption. The actual host's default WSL distro is `<your-distro>`; the `admin` user lives there. `wsl -d Ubuntu -u admin` therefore failed `getpwnam`.
2. `Wait-WSL` invoked `wsl ...` and called it a success based on PowerShell exception handling. PowerShell does NOT auto-throw on native-command non-zero exit -- it only throws for cmdlet errors. The non-zero exit from WSL was silently dropped.

**Fix:**
- Introduced `Invoke-WSL` helper in [windows/auto-start.ps1](../windows/auto-start.ps1) that explicitly checks `$LASTEXITCODE` after every `wsl` call and throws if non-zero. Both `Wait-WSL` and `Start-CodeServer` route through it.
- Made `$WSL_DISTRO` optional: if empty, `Invoke-WSL` omits the `-d` flag and uses the default distro (matches the original pre-rewrite behavior).
- Set live config `E:\code\auto-start.config.ps1` to `$WSL_DISTRO = "<your-distro>"` explicitly so a future change of default distro doesn't silently break.
- Saved [memory entry](../../.claude/projects/e--code-remote-vscode-wsl-cloudflare/memory/project_wsl_distros.md) documenting which distros exist and which one hosts the deployment.

**Prevention:** ANY native-command call in a `.ps1` script that needs to detect failure must check `$LASTEXITCODE` explicitly. PowerShell's exception model only covers cmdlets, not native processes. Codified as a stdlib helper (`Invoke-WSL`) so the check can't be forgotten.

---

## RCA-003: Em-dash characters in `.ps1` source broke the PS 5.1 parser (2026-04-26)

**Symptom:** Running `auto-start.ps1` produced cascading parser errors:

```text
The token '||' is not a valid statement separator in this version.
Unexpected token 'likely' in expression or statement.
Missing closing ')' in expression.
The string is missing the terminator: ".
Missing closing '}' in statement block or type definition.
```

The `||` was inside a quoted string (legal). The "missing terminator" was on a line with no obvious quote issue. The errors were on lines that appeared syntactically clean.

**Root cause:** the file was written as UTF-8 *without* BOM. Windows PowerShell 5.1 reads files as the active code page (CP-1252 in this locale) when no BOM is present. Em-dash characters (`—`, U+2014, three bytes `E2 80 94` in UTF-8) get decoded as the CP-1252 sequence `â€"`. The third byte `0x94` in CP-1252 is U+201D (right double quotation mark) -- which the parser treats as a closing quote, prematurely terminating any string the em-dash appeared in. The downstream `||`, `likely`, missing `)` errors are all collateral damage from a string that closed early dozens of lines earlier.

**Fix:** rewrote [windows/auto-start.ps1](../windows/auto-start.ps1) with ASCII-only characters. Replaced every em-dash with `--`. Same for `auto-start.config.example.ps1` and `auto-start.config.ps1`. Verification: `LC_ALL=C grep -nP "[^\x00-\x7F]"` returns no hits for the touched files.

**Prevention:**
- Saved [memory entry](../../.claude/projects/e--code-remote-vscode-wsl-cloudflare/memory/feedback_powershell_encoding.md) for future sessions: never use non-ASCII in `.ps1` files.
- Verification step is now part of the workflow: `LC_ALL=C grep -nP "[^\x00-\x7F]" path/to/file.ps1` should return nothing before any PS1 commit.
- Long-term option (not yet adopted): write `.ps1` files with UTF-8 BOM. Not adopted because the Write tool produces bare UTF-8 by default; ASCII-only is bulletproof regardless of the writer.

---

## RCA-002: `Stop-Process` Access denied because cloudflared was elevated (2026-04-26)

**Symptom:** Manual re-runs of `auto-start.ps1` from a non-elevated PowerShell consistently failed:

```text
[Tunnel Start] Attempt 1..5
Stop-Process: Cannot stop process "cloudflared (15160)" because of the following error: Access is denied
FAILED: Tunnel Start failed after 5 attempts
```

Hit twice in the live transcript before the rewrite (Apr 23 09:06, Apr 24 17:09). Worse: the script ran `Start-CodeServer` *before* `Start-Tunnel`, and that stage *did* successfully kill and relaunch code-server -- silently dropping any active in-browser sessions for nothing.

**Root cause:** Task Scheduler ran the original `auto-start.ps1` with "Run with highest privileges". The cloudflared spawned that way is owned by an elevated process. A non-elevated manual re-run cannot `Stop-Process` an elevated process (Windows ACL). The original script's `Start-Tunnel` blindly called `Stop-Process -Force` at the start of every attempt, regardless of whether the tunnel was already healthy.

**Fix:** made both `Start-Tunnel` and `Start-CodeServer` idempotent in [windows/auto-start.ps1](../windows/auto-start.ps1):
- `Start-Tunnel` now fast-paths (no kill, no restart) if cloudflared is alive AND `Test-PublicTunnel` returns true. Only falls through to kill+restart if the tunnel is actually unhealthy.
- `Start-CodeServer` fast-paths if `Test-LocalHTTP` returns true. Stops dropping active sessions on every re-run.
- When a kill IS needed and Stop-Process fails, the error message now explicitly explains the elevation cause and points the operator at the fix ("run from elevated shell, or stop cloudflared manually").

**Prevention:** the broader pattern -- "blind kill+restart at the top of every retry attempt" -- is gone from this codebase. Every "ensure X is running" function now reads as: probe first, skip if healthy, only mutate state if necessary. Codified as a project convention.

---

## RCA-001: `READY -> https://...` was logged with no actual tunnel verification (2026-04-26)

**Symptom:** Original `auto-start.ps1` logged `READY -> https://dev.yourdomain.com` and Task Scheduler reported success even when cloudflared was dead. Operator only noticed when a browser hit the URL and saw Cloudflare Error 1033.

**Root cause:** the "tunnel started" check probed `http://127.0.0.1:8081` -- which is **code-server**, not the tunnel. A successful probe proves code-server is up; it tells you nothing about whether cloudflared is alive or whether the public URL works. The check measured the wrong thing.

**Fix:** [windows/auto-start.ps1](../windows/auto-start.ps1) introduces `Test-PublicTunnel` that probes `https://$PUBLIC_HOST` -- the canonical end-to-end signal. If that returns 2xx/3xx/4xx, the entire chain (cloudflared -> Cloudflare edge -> Access -> origin) is verified. Used by the fast-path skip *and* by the post-launch verification *and* by `health-check.ps1`.

**Prevention:** project convention: "is X working" must be measured against X's user-visible behavior, not against an internal proxy. For this stack, the user-visible behavior is "the public URL answers" -- everything else is plumbing.
