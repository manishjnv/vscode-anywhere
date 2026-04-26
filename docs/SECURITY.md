# Security

An honest threat model for this setup. This is a personal dev environment, not a production service — the goal is "reasonably safe for one developer exposing their own laptop to themselves" rather than SOC2-compliant.

## What this setup protects against

### ✅ Random internet attackers
Your hostname resolves to Cloudflare's edge, not your home IP. Cloudflare Access stops every unauthenticated request at the edge — requests never reach your laptop. An attacker would need to compromise Google SSO or Cloudflare itself.

### ✅ Your home network being exposed
`cloudflared` is outbound-only. Your router has no forwarded ports. Port scanning your home IP tells an attacker nothing about this setup. There's no NAT traversal, UPnP, or dynamic DNS involved.

### ✅ TLS interception on public networks
All traffic between browser and Cloudflare is HTTPS with Cloudflare's certs. On a coffee shop WiFi, an attacker can see you're connecting to `dev.yourdomain.com` but can't see what you're doing.

### ✅ Credential theft via keylogger-less phishing
You never type a password for code-server — Access uses Google OAuth with a redirect flow. A malicious site can't trick you into giving it code-server creds because there are none.

## What this setup does NOT protect against

### ⚠️ Malicious browser extensions
If your browser has a malicious extension with access to `dev.yourdomain.com`, it can read and modify anything in your code-server session. This is true of any web IDE. Mitigation: use a dedicated browser profile with minimal extensions for dev work.

### ⚠️ A compromised Google account
If your Google account is compromised, an attacker signs into Access as you. Mitigation: enable Google 2FA with a hardware key. Add a Cloudflare Access policy that requires a specific authentication method (e.g., "require hardware key").

### ⚠️ Someone with physical access to your Windows laptop
This setup has no magic defense against this. Mitigation: Windows login password, BitLocker full-disk encryption, screen lock timeout. All standard laptop hygiene.

### ⚠️ Supply chain in the stack
`code-server`, `cloudflared`, Open VSX extensions, npm packages Claude Code pulls in — each is a trust boundary. A compromised VS Code extension has the same access as VS Code itself.

### ⚠️ Claude Code in bypass-permissions mode
If you use `claude --dangerously-skip-permissions` (or `bypass permissions on` in the TUI), the agent can read and write any file in your project and execute arbitrary shell commands without asking. Combined with a public tunnel, if an attacker somehow got past Cloudflare Access (compromised Google account), they'd have an AI agent with shell access waiting for them. Mitigation: default approval mode, or restrict `claude` to running only inside a container/sandbox.

## Configuration requirements

### MUST DO

1. **Cloudflare Access in front of the tunnel.** Without this, `auth: none` on code-server exposes your entire dev laptop to the internet. A search engine will find your hostname, a bot will hit it, and now someone has a terminal on your machine.

2. **Enable Google 2FA on the account you use for Access.** SSO is only as secure as the identity provider.

3. **Use a dedicated email address for Access** if you can. Narrows blast radius if something goes wrong.

### SHOULD DO

4. **Set Access session duration to something sensible** (24h for personal dev, 8h if you want to re-auth daily).

5. **Enable Cloudflare Access audit logs** to see who's signing in.

6. **Review `/tmp/code-server.log` and `E:\code\remote-vscode-wsl-cloudflare\logs\startup.log` periodically** for anything weird.

7. **Keep code-server, cloudflared, and your WSL distro updated.** These are the three most important pieces to patch.

### NICE TO HAVE

8. **Add an additional Access policy requiring a specific IP range** (e.g., your home + phone carrier) for an extra layer beyond SSO.

9. **Use Cloudflare Access's "Warp Required" option** to restrict access to devices enrolled in Cloudflare WARP.

10. **Lock down the WSL user account** — don't give it passwordless sudo if you can avoid it. If Claude Code is going to run privileged commands, prefer containerized execution.

## What "auth: none" actually means

`auth: none` in `~/.config/code-server/config.yaml` disables code-server's built-in password prompt. It does NOT mean "no authentication anywhere in the stack." In this setup, authentication moves up a layer to Cloudflare Access, which is stronger than code-server's built-in password for every real-world threat.

If you remove Cloudflare Access but keep `auth: none`, you have published a terminal to the internet. Don't do that.

## Revoking access

Need to lock yourself (or someone else) out immediately?

1. **Cloudflare Zero Trust → Access → Applications → Dev Environment → Policies** → remove or restrict the allow policy. New requests are blocked within seconds.
2. **Kill active sessions:** Zero Trust → Logs → Access → find your sessions → revoke.
3. **Disable the tunnel entirely:** stop `cloudflared` on the Windows laptop (`Stop-Process -Name cloudflared`) or delete the tunnel from the Cloudflare dashboard. The hostname goes 502 / blackholes.
