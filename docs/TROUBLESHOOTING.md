# Troubleshooting

Every failure mode hit while building this setup, plus the usual suspects.

## Extensions pane shows "0" for Popular and Recommended

**Symptom:** The Extensions sidebar shows `DEV.YOURDOMAIN.COM - INSTALLED: 0`, `POPULAR: 0`, `RECOMMENDED: 0`. Search returns nothing.

**Cause:** code-server 4.x doesn't ship with a default extensions gallery baked into `product.json` in every build variant. Without an explicit `EXTENSIONS_GALLERY` env var, code-server has nowhere to query for extensions.

**Fix:** The `wsl/start-code-server.sh` in this repo exports `EXTENSIONS_GALLERY` before launching. If the pane is still empty:

```bash
# Confirm the env var made it into the running node process
cat /proc/$(pgrep -f 'node.*code-server' | head -1)/environ | tr '\0' '\n' | grep GALLERY
# Should print EXTENSIONS_GALLERY={"serviceUrl":"https://open-vsx.org/vscode/gallery",...}
```

If it prints nothing, your `start-code-server.sh` isn't exporting it — verify you copied it from this repo verbatim.

If it does print but the UI is still empty: the browser is holding stale state. Close the tab fully (not just reload), reopen, hard reload with `Ctrl+Shift+R`. If still empty, clear site data in DevTools → Application → Clear Storage, then reload.

---

## auto-start.ps1 fails with "HTTP Ready failed after 15 attempts"

**Symptom:** In `startup.log`:
```
[HTTP Ready] Attempt 1
PS>TerminatingError(Invoke-WebRequest): "The operation has timed out."
...
FAILED: HTTP Ready failed after 15 attempts
```

Despite code-server actually being up and listening on the port.

**Cause:** PowerShell resolves `localhost` to `::1` (IPv6 loopback) first, but WSL2's localhost-forwarding is IPv4-only. The probe times out on IPv6 while code-server happily serves on IPv4.

**Fix:** Use `127.0.0.1` instead of `localhost` in `auto-start.ps1`. The version in this repo already does. If you're adapting an older script:

```bash
# From WSL, fix an existing script in /mnt/e/...
sed -i 's|http://localhost:|http://127.0.0.1:|g' /mnt/e/code/auto-start.ps1
```

---

## Browser loads dev.yourdomain.com but shows "Error 1033" or similar

**Symptom:** Cloudflare-branded error page (1033, 1034, 502).

**Cause:** Tunnel is not running, or cloudflared can't reach `127.0.0.1:8081`.

**Fix checklist:**

```powershell
# Is cloudflared running?
Get-Process cloudflared

# Is code-server actually listening on the Windows side?
Invoke-WebRequest http://127.0.0.1:8081 -UseBasicParsing | Select-Object StatusCode

# If that works, restart the tunnel
Get-Process cloudflared | Stop-Process -Force
Start-Process cloudflared -ArgumentList "tunnel run dev-tunnel"
```

If `Invoke-WebRequest` times out, code-server isn't reachable from Windows. Check WSL:

```powershell
wsl -u admin -e bash -lc "ss -tulnp | grep 8081"
```

Empty → code-server isn't running. Restart it: `wsl -u admin -e bash -lc "/home/admin/start-code-server.sh"`

---

## "Your IP is blocked" or bot detection page

**Symptom:** You reach a Cloudflare challenge / CAPTCHA page before hitting Access.

**Cause:** Cloudflare's bot fight mode or security level is too high for your IP.

**Fix:** In the Cloudflare dashboard for your domain → Security → Settings → drop the security level for your hostname. Or add a WAF rule allowing your IP range.

---

## Access loop: after Google login, sent back to Google login

**Symptom:** You sign in with Google, get redirected back to the Access page, which redirects to Google again.

**Cause:** Cookie domain mismatch, or your browser is blocking third-party cookies, or you have two Access applications covering the same hostname with conflicting policies.

**Fix:**

1. Allow third-party cookies for `cloudflareaccess.com` in your browser settings
2. In Zero Trust → Access → Applications, make sure only ONE application matches `dev.yourdomain.com`
3. Clear cookies for your domain and `cloudflareaccess.com`, retry

---

## WSL commands from PowerShell time out or hang

**Symptom:** `wsl -e bash -lc "echo ready"` never returns, or takes 30+ seconds.

**Cause:** WSL2 distro is in a bad state. Usually happens after a Windows update.

**Fix:**

```powershell
wsl --shutdown
Start-Sleep 5
wsl -d Ubuntu -e bash -lc "echo ready"
```

If it still hangs, check WSL version:

```powershell
wsl --version
wsl --update
```

---

## Extensions installed but don't load / errors about "extension host terminated unexpectedly"

**Symptom:** Python extension (or any other) installs, but opening a .py file shows "Extension Host terminated" in the bottom-right.

**Cause:** Usually a Node.js version mismatch or the extension requires a newer VS Code engine than code-server ships.

**Fix checklist:**

```bash
# Check code-server's bundled Node
code-server --help 2>&1 | head -5

# Look at the log for the exact error
tail -50 /tmp/code-server.log

# Try reinstalling the specific extension
code-server --uninstall-extension ms-python.python
code-server --install-extension ms-python.python
```

If the extension demands a newer VS Code engine, check if an older version of the extension is available on Open VSX that's compatible:

```bash
curl -s https://open-vsx.org/api/ms-python/python | jq .allVersions
```

---

## "Claude Code: Invalid authentication" after login

**Symptom:** `claude` opens a browser for OAuth, you authenticate, come back to the terminal, and it says auth failed.

**Cause:** Claude Code's OAuth callback requires hitting a `localhost` port on the same machine. In this remote setup, your browser is on your phone/laptop but Claude Code is running in WSL — the callback can't reach back.

**Fix:** code-server's automatic port forwarding handles this — when Claude Code opens its local OAuth server, code-server exposes it via `https://dev.yourdomain.com/proxy/<port>/`. If it's not working:

1. In code-server, open Ports panel — you should see the Claude port listed
2. Make sure "Auto forward ports" is enabled (Settings → search "remote.autoForwardPorts")
3. If still failing, log in with an API key instead: `export ANTHROPIC_API_KEY=sk-ant-...`

---

## Startup script runs but auto-start doesn't fire at logon

**Symptom:** Manual `powershell -File auto-start.ps1` works. Task Scheduler task doesn't fire at logon.

**Fix checklist:**

1. Task Scheduler → your task → Last Run Result — anything but `0x0` means it failed. Common culprits:
   - `0x1` — action returned non-zero. Check `startup.log`.
   - `0x41301` — still running from previous trigger. You probably clicked "Run" manually twice.
2. Trigger is set to "At log on" and matches your username, not "Any user"
3. Principal tab (via XML export) shows LogonType as `InteractiveToken`
4. Action's "Start in" directory exists and is writable
5. Execution policy isn't blocking — the `-ExecutionPolicy Bypass` arg should handle this, but verify with `Get-ExecutionPolicy -List`

Export the task to XML to diff against a known-good version:
```powershell
schtasks /query /tn "Dev Environment Startup" /xml > task.xml
```

---

## Every time I reload, my VS Code settings reset

**Cause:** You're editing settings inside a code-server session but they're going to `~/.local/share/code-server/User/settings.json` which isn't being persisted.

**Fix:** Make sure `~/.local/share/code-server/` is on WSL's filesystem, not a volatile mount. By default it is. Check:

```bash
ls -la ~/.local/share/code-server/User/settings.json
```

If the file exists and persists, but settings appear to reset, it's likely a Settings Sync issue — disable Settings Sync in VS Code if you had it on (it tries to sync against Microsoft's servers which code-server can't reach).

---

## Can I install the official Claude Code VS Code extension?

Not from Open VSX — it's only on Microsoft's marketplace. Options:

1. **Run `claude` CLI in the integrated terminal** — works identically, no extension needed. Recommended.
2. **Sideload the `.vsix`:** download from Anthropic's releases page on a machine that can reach MS marketplace, transfer the file to WSL, then `code-server --install-extension /path/to/anthropic.claude-code-*.vsix`.

---

## Can I connect from my phone?

Yes. Any mobile browser works. code-server's UI is usable but cramped on phones — it's really designed for tablets and laptops. On iPad in particular, Safari + a Bluetooth keyboard works surprisingly well.

---

## Help, I'm hitting something not in this doc

Check in this order:

1. `E:\code\startup.log` — the PowerShell transcript
2. `/tmp/code-server.log` inside WSL — code-server's output
3. `cloudflared` logs — `Get-EventLog Application -Source cloudflared` on Windows, or run `cloudflared tunnel run dev-tunnel` in the foreground to see live
4. Cloudflare Zero Trust → Logs → Access — authentication failures

If it's a code-server bug, the [code-server issues tracker](https://github.com/coder/code-server/issues) is active. If it's a tunnel issue, Cloudflare's community forum is responsive.
