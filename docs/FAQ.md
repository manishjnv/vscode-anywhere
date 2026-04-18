# FAQ

## Is this free?

Yes, for personal use. Cloudflare Tunnel and Cloudflare Access both have generous free tiers (Access free up to 50 users). Open VSX is free. code-server is free and open source. The only thing you might pay for is a domain name (~$10/year for a `.com`).

## How does this compare to GitHub Codespaces?

| | This setup | Codespaces |
|---|---|---|
| Compute | Your own laptop | GitHub's cloud |
| Cost | Free (domain ~$10/yr) | $0.18/hr for 2-core, ~$130/mo if on 8hr/day |
| Performance | As fast as your laptop | Capped at the SKU you pick |
| Internet offline | Works if you're on your LAN | Dead |
| Your code | Stays on your disk | Uploaded to GitHub |
| Setup effort | ~45 min one-time | Zero |
| Boot time | Always on | 30–60s cold start |

Different tools for different problems. If you value control and have a capable laptop that's on most of the time, this wins. If you want zero setup and are fine with your code living on GitHub, Codespaces wins.

## Will this work with my corporate Google account?

Probably yes, unless your org has locked third-party OAuth apps. You can also point Cloudflare Access at Okta, Azure AD, GitHub, OIDC providers, or SAML IdPs. Cloudflare Access supports most of the enterprise identity ecosystem.

## Can I use this for a small team?

Yes — Cloudflare Access free tier allows up to 50 users. Add more emails to the Access policy (or an email domain rule like `@yourcompany.com`). Each teammate gets their own Google login; code-server itself is shared.

**Caveat:** code-server doesn't have per-user isolation. Every authenticated user has access to the same project files and terminal. Fine for a trusted team on a shared dev box. Not fine for multi-tenant isolation. If you need per-user isolation, each user needs their own WSL instance on their own machine with their own tunnel.

## What if my laptop goes to sleep?

The tunnel dies when the laptop sleeps, and the hostname shows Cloudflare's 502 page. When the laptop wakes up, `cloudflared` reconnects automatically within 5-10 seconds.

Tips:
- **Power plan:** set "Plugged in / Sleep: Never" if the laptop is mostly on a desk. Keep "On battery / Sleep" to something reasonable.
- **Allow WSL to survive sleep:** WSL2 generally handles sleep/wake cleanly, but code-server sometimes needs a restart. The auto-start PS1 handles this if you unlock/relock, because Task Scheduler can be configured to retrigger on workstation unlock.

## Will my laptop overheat from running code-server 24/7?

code-server idle costs almost nothing (~1% of one CPU core). Your laptop is doing more work rendering the clock than running code-server at rest. Under active use, load is comparable to running desktop VS Code.

## Can I access files outside /mnt/e/code?

Yes — in WSL's terminal you have the full Linux filesystem and `/mnt/c`, `/mnt/d`, etc. for all Windows drives. The `PROJECT_DIR` in `start-code-server.sh` just sets the default folder that opens on connection. Once in, you can File → Open Folder to anything.

## Does this work on Mac or Linux as the host?

This specific repo is Windows + WSL2 specific. The same architecture (code-server + cloudflared + Access) works on macOS and Linux hosts — you'd skip the WSL layer and run code-server natively. The orchestration script would be bash instead of PowerShell, and you'd use launchd or systemd instead of Task Scheduler.

Not in scope for this repo, but the moving parts transfer 1:1.

## What about Claude Code / Cursor / other AI coding tools?

- **Claude Code CLI:** works great in the terminal (`npm install -g @anthropic-ai/claude-code`)
- **Cursor:** not supported — Cursor is a desktop fork of VS Code, not a code-server extension
- **Continue.dev, Cline, Kilo Code:** available on Open VSX, install via the marketplace

## How do I back this up?

Your code should be in git anyway. Beyond that:

- **Windows side:** back up `C:\Users\<you>\.cloudflared\` (tunnel creds) and `E:\code\auto-start.ps1`
- **WSL side:** back up `~/.config/code-server/`, `~/start-code-server.sh`, and `~/.local/share/code-server/User/` (your VS Code settings and keybindings)

Export the Task Scheduler task to XML:
```powershell
schtasks /query /tn "Dev Environment Startup" /xml > task-backup.xml
```

## Can I run multiple code-server instances for different projects?

Yes. Change the port in `start-code-server.sh` (e.g., 8082 for a second project), add a second ingress rule in `cloudflared-config.yml` with a different hostname, route a new DNS for it, create a new Access app.

Better alternative: use code-server Workspaces. One code-server instance, switch between project folders via File → Open Folder. Simpler than running two servers.

## Why didn't you just use Coder or Gitpod self-hosted?

Overkill for a single-developer personal setup. Those are team platforms with their own dashboards, RBAC, and operational overhead. For one person on one laptop, `code-server + cloudflared` is a dozen lines of config versus a docker-compose stack.

## How do I uninstall this cleanly?

```powershell
# Remove Task Scheduler task
schtasks /delete /tn "Dev Environment Startup" /f

# Stop and delete the tunnel
Get-Process cloudflared | Stop-Process -Force
cloudflared tunnel delete dev-tunnel

# Remove the DNS record (Cloudflare dashboard → DNS → delete the CNAME)

# Remove the Access application (Zero Trust → Access → Applications → delete)

# Uninstall cloudflared
winget uninstall --id Cloudflare.cloudflared
```

In WSL:
```bash
# Stop code-server
fuser -k 8081/tcp

# Uninstall
sudo apt remove code-server   # or the path your installer used

# Remove config
rm -rf ~/.config/code-server ~/.local/share/code-server ~/start-code-server.sh
```

Delete your domain from Cloudflare if you don't need it anymore.
