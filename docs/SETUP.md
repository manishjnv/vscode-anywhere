# Setup Guide

End-to-end install. Budget ~45 minutes if this is your first time with Cloudflare Tunnel or WSL. The setup is one-time; after you're done, everything starts automatically at logon forever.

## Before you start

You need:

- **Windows 10 or 11** with WSL2 and a Linux distro installed (Ubuntu, Debian, Kali — any work)
- **A domain on Cloudflare** — can be any TLD. You don't need a paid plan; the free tier covers tunnels and Access
- **A Google account** for SSO (or any other identity provider Cloudflare Access supports)
- **About 20 GB free disk space** for WSL and extensions

Test WSL works first:
```powershell
wsl -d Ubuntu -e bash -lc "echo hello from WSL"
```

If that doesn't print `hello from WSL`, fix your WSL install before continuing. Microsoft's [WSL install docs](https://learn.microsoft.com/en-us/windows/wsl/install) cover it.

## Step 1 — Install code-server in WSL

Open a WSL terminal as the user who'll own the dev environment. In the examples below I use `admin`; substitute your own.

```bash
# Install code-server (official one-liner from coder/code-server)
curl -fsSL https://code-server.dev/install.sh | sh

# Verify
code-server --version
# Should print something like: 4.116.0
```

Create the config directory and drop in the config:

```bash
mkdir -p ~/.config/code-server
```

Copy `wsl/code-server-config.yaml` from this repo to `~/.config/code-server/config.yaml`.

Copy `wsl/start-code-server.sh` to `~/start-code-server.sh` and make it executable:

```bash
chmod +x ~/start-code-server.sh
```

**Smoke test:**

```bash
~/start-code-server.sh
```

Expected output:
```
[WSL] Starting code-server...
[WSL] code-server is LISTENING on 8081
```

From a Windows PowerShell (not WSL), verify it's reachable through WSL2's localhost-forwarding:

```powershell
Invoke-WebRequest http://127.0.0.1:8081 -UseBasicParsing | Select-Object StatusCode
# Should print 200
```

If that works, code-server is healthy. Kill it with `fuser -k 8081/tcp` in WSL — the auto-start script will relaunch it later.

## Step 2 — Install cloudflared on Windows

```powershell
winget install --id Cloudflare.cloudflared
# Restart PowerShell so cloudflared is on PATH
cloudflared --version
```

Log into your Cloudflare account (opens a browser for you to authorize):

```powershell
cloudflared tunnel login
```

This writes a cert to `C:\Users\<you>\.cloudflared\cert.pem`. Pick the domain you'll use for this when the browser prompts.

Create a named tunnel:

```powershell
cloudflared tunnel create dev-tunnel
```

This prints a UUID and writes credentials to `C:\Users\<you>\.cloudflared\<UUID>.json`. **Copy that UUID** — you'll paste it into the config file next.

Route your chosen hostname through the tunnel (this creates a CNAME in your Cloudflare DNS pointing at the tunnel):

```powershell
cloudflared tunnel route dns dev-tunnel dev.yourdomain.com
```

Now copy `windows/cloudflared-config.yml` from this repo to `C:\Users\<you>\.cloudflared\config.yml` and edit three things:

- `tunnel:` — paste your tunnel UUID
- `credentials-file:` — point at the JSON file `cloudflared` wrote
- `hostname:` — your hostname (matches what you passed to `route dns`)

**Smoke test:** with code-server running in WSL:

```powershell
cloudflared tunnel run dev-tunnel
```

Open `https://dev.yourdomain.com` in a browser. You should see the code-server UI (with no login yet — we add that in Step 5).

`Ctrl+C` to stop the tunnel. The auto-start script will launch it later.

## Step 3 — Drop the auto-start script on Windows

Put `windows/auto-start.ps1` anywhere convenient. I use `E:\code\auto-start.ps1`; adjust paths to taste.

Edit the CONFIG section at the top to match your setup:

```powershell
$WSL_USER = "admin"                 # Your WSL username
$PORT     = 8081                    # code-server port
$TUNNEL   = "dev-tunnel"            # Your tunnel name
$LOG      = "E:\code\startup.log"   # Where to write the transcript
```

Also change the `READY -> https://dev.yourdomain.com` line near the bottom to your hostname — it's cosmetic but nice to have in the log.

Test the full script by running it manually:

```powershell
powershell -ExecutionPolicy Bypass -File E:\code\auto-start.ps1
```

Watch the log:

```powershell
Get-Content E:\code\startup.log -Tail 30
```

You should see all stages pass on attempt 1 and end with `READY -> https://...`. If not, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Step 4 — Register a Task Scheduler task for auto-start

This makes the whole stack come up automatically when you log in.

Open Task Scheduler (`taskschd.msc`) → **Create Task...** (not "Create Basic Task" — you need the advanced dialog).

**General tab:**
- Name: `Dev Environment Startup`
- Check: **Run only when user is logged on**
- Check: **Run with highest privileges**
- Configure for: Windows 10

**Triggers tab:**
- New... → Begin the task: **At log on** → Specific user: your account → Delay task for: **30 seconds**

**Actions tab:**
- New... → Action: **Start a program**
- Program: `powershell`
- Arguments: `-WindowStyle Hidden -ExecutionPolicy Bypass -File "E:\code\auto-start.ps1"`
- Start in: `E:\code`

**Conditions tab:**
- **Uncheck** "Start the task only if the computer is on AC power" (so it runs on battery too if you're on a laptop)

**Settings tab:**
- Check: **If the task fails, restart every:** 1 minute, up to 3 attempts

OK to save. Log out and back in (or reboot) to verify. After logon, give it a minute, then open your hostname. Should Just Work™.

## Step 5 — Protect it with Cloudflare Access (Google SSO)

**This step is non-negotiable.** Your code-server is running with `auth: none` and is reachable from the public internet — anyone with your hostname can get a full shell on your laptop unless Access is in front of it.

Go to the Cloudflare dashboard → **Zero Trust** (left sidebar — may prompt you to set up a Zero Trust team name first; any name is fine, the team plan has a free tier with 50 users).

Once in Zero Trust:

**Settings → Authentication → Login methods → Add new:**
- Pick **Google**
- Follow Cloudflare's walkthrough to create OAuth credentials in Google Cloud Console, paste Client ID + Secret back into Cloudflare
- Test — should show a green "Test successful" when you sign in with your Google account

**Access → Applications → Add an application:**
- Type: **Self-hosted**
- Application name: `Dev Environment`
- Session Duration: 24 hours (or whatever works for you)
- Application domain: `dev.yourdomain.com`

Click **Next**. Now create a policy:
- Policy name: `Me`
- Action: **Allow**
- Configure rules: **Emails** → `your.email@gmail.com`

Save. Open an incognito browser tab and go to your hostname. You should get a Cloudflare Access login page → sign in with Google → land in code-server.

**Verify it's really gating access:** open the hostname in another browser where you're NOT signed into that Google account. You should be blocked at the Access screen, not forwarded to code-server.

## Step 6 — (Optional but recommended) Install Claude Code in the terminal

Inside code-server's integrated terminal (Terminal menu → New Terminal):

```bash
# Install Claude Code CLI
npm install -g @anthropic-ai/claude-code

# First run — triggers browser OAuth for your Claude account
claude
```

If you have a Claude Max subscription, it picks it up automatically. You now have an AI coding agent in your remote dev environment.

## Step 7 — Install VS Code extensions

From the code-server integrated terminal:

```bash
code-server --install-extension ms-python.python
code-server --install-extension ms-azuretools.vscode-docker
code-server --install-extension redhat.vscode-yaml
code-server --install-extension eamodio.gitlens
code-server --install-extension ms-toolsai.jupyter
code-server --install-extension esbenp.prettier-vscode
code-server --list-extensions
```

Or use the Extensions sidebar UI — search works because we pointed `EXTENSIONS_GALLERY` at Open VSX in `start-code-server.sh`.

**Heads up:** Open VSX doesn't have every extension on Microsoft's marketplace. If you need one that's MS-only (e.g. official Claude Code VS Code extension), grab the `.vsix` from the publisher's GitHub releases and install via:
```bash
code-server --install-extension /path/to/extension.vsix
```

## You're done

Reboot once more to confirm the full chain comes up on its own. Open your hostname from any browser, sign in with Google, and you're coding.

Read [SECURITY.md](SECURITY.md) for a rundown of what the security boundary actually protects. Read [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if anything in this guide didn't work — every failure mode I hit is documented there.
