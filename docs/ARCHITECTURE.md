# Architecture

How the pieces fit together, and why each choice was made.

## High-level flow

```
┌──────────────┐       HTTPS + Google SSO        ┌──────────────────┐
│   Browser    │ ──────────────────────────────► │  Cloudflare Edge │
│  (anywhere)  │                                  │  (Access + TLS)  │
└──────────────┘                                  └────────┬─────────┘
                                                            │
                                                   outbound-only
                                                   tunnel (QUIC)
                                                            │
                                                            ▼
                                                  ┌──────────────────┐
                                                  │   cloudflared    │
                                                  │  (Windows host)  │
                                                  └────────┬─────────┘
                                                            │
                                                   http://127.0.0.1:8081
                                                            │
                                                     WSL2 localhost
                                                      forwarding
                                                            │
                                                            ▼
                                                  ┌──────────────────┐
                                                  │   code-server    │
                                                  │    (WSL2)        │
                                                  └────────┬─────────┘
                                                            │
                                                            ▼
                                                  /mnt/e/code/...
                                                  (your project tree)
```

## Layer by layer

### 1. Browser → Cloudflare edge

Standard HTTPS. Cloudflare terminates TLS at the edge using its wildcard cert for your domain. You never configure certs yourself.

Before the request reaches your laptop, Cloudflare Access checks for a valid session cookie. If missing or expired, Access redirects to Google SSO. On successful login, Access issues a signed JWT cookie for your `dev.yourdomain.com` hostname and forwards the original request.

### 2. Cloudflare edge → cloudflared

Cloudflare Tunnel uses QUIC (or falls back to HTTP/2) over an outbound-only connection from your laptop to the nearest Cloudflare point of presence. The daemon (`cloudflared`) keeps this connection open persistently.

**Why this matters for security:** your home router exposes zero inbound ports. No port forwarding, no NAT punching, no dynamic DNS. The tunnel is initiated by the laptop, and Cloudflare routes traffic back over that already-established connection.

### 3. cloudflared → 127.0.0.1:8081

The `ingress` rule in `config.yml` maps `hostname: dev.yourdomain.com` → `service: http://127.0.0.1:8081`. The tunnel daemon forwards decrypted traffic to that local URL.

**Why 127.0.0.1 and not localhost:** WSL2's localhost-forwarding magic is IPv4-only. Windows resolves `localhost` to `::1` (IPv6 loopback) by default, and WSL2 doesn't forward IPv6 loopback. Using `127.0.0.1` in `cloudflared` config and in the PowerShell readiness probe avoids a silent 45-second timeout loop.

### 4. 127.0.0.1:8081 → WSL2

When code-server binds to `0.0.0.0:8081` inside WSL2, the WSL2 kernel network driver mirrors that port to `127.0.0.1:8081` on the Windows host. This is the "localhost forwarding" feature that makes WSL2 feel like a seamless Linux sub-system.

### 5. code-server serves the UI and project files

`code-server` is a fork of VS Code that runs as an HTTP server instead of a desktop app. It serves the full VS Code UI (as a web app built from the VS Code source) to the browser, and on the backend it has access to the entire Linux userspace: the file system, git, docker (if you have docker-desktop WSL integration), Python, Node, your whole dev toolchain.

The project directory is passed as a CLI arg (`/mnt/e/code` in this setup), so when you connect, VS Code opens there. `/mnt/e/...` is WSL2's view of the Windows `E:\` drive — edits are real-time visible from both sides.

## The auto-start chain at boot

```
Windows logon
    │
    ▼
Task Scheduler fires "Dev Environment Startup" (30s delay)
    │
    ▼
powershell.exe launches auto-start.ps1 (hidden window)
    │
    ▼
Start-Sleep 30   # absorbs WSL/network cold-boot lag
    │
    ├── Wait-Network       (DNS resolves argotunnel.com)
    ├── Ensure-WSL         (WSL responds to `echo ready`)
    ├── Start-CodeServer   (runs ~/start-code-server.sh in WSL)
    ├── Wait-HTTP          (127.0.0.1:8081 returns 200)
    └── Start-Tunnel       (cloudflared tunnel run)
    │
    ▼
READY -> https://dev.yourdomain.com
```

Each stage retries on failure. If the whole chain fails, `FAILED: <message>` goes to `E:\code\remote-vscode-wsl-cloudflare\logs\startup.log` and you can re-run manually.

## Why each component was chosen

### code-server vs VS Code Web vs other web IDEs

- **Microsoft VS Code Web** (vscode.dev) won't give you a local Linux runtime — you'd still need to BYO compute
- **Gitpod / Coder** are great but are managed services (cost money, your code lives on their infra)
- **code-server** gives you the full VS Code UX against your own machine, self-hosted, free

Tradeoff: code-server can't use Microsoft's extension marketplace (licensing). Open VSX covers 95% of what you need; `.vsix` sideload covers the rest.

### Cloudflare Tunnel vs ngrok vs Tailscale

- **ngrok** free tier rotates URLs, paid is $$, and you'd still need to put auth in front yourself
- **Tailscale** is excellent but requires a Tailscale client on every device you connect from — doesn't work from a public library computer or a friend's browser
- **Cloudflare Tunnel** gives you a stable public hostname with zero inbound ports and Access handles auth. Free tier is generous.

### Cloudflare Access vs code-server's built-in password

- code-server's built-in auth is a single shared password sent in a cookie. No SSO, no MFA, no session management, no per-device revocation.
- Cloudflare Access gives you Google/GitHub/Okta SSO, session duration controls, per-user revocation, audit logs, and optional MFA — all for free.

## What lives where

| File | Machine | Purpose |
|---|---|---|
| `auto-start.ps1` | Windows | Boot orchestration |
| `cloudflared-config.yml` | Windows | Tunnel ingress rules |
| `cloudflared.exe` | Windows | Tunnel daemon |
| `start-code-server.sh` | WSL | Launches code-server with gallery config |
| `~/.config/code-server/config.yaml` | WSL | bind-addr, auth settings |
| `code-server` binary | WSL | The VS Code web server itself |
| Project code | `E:\code\...` (Windows) / `/mnt/e/code/...` (WSL) | Same bytes, two views |

## What doesn't live anywhere

No state is kept on Cloudflare. No code is uploaded to any third-party service. Every edit happens on your laptop's disk. Cloudflare only sees encrypted HTTP traffic passing through; it never decrypts your files at rest because there's nothing to decrypt — the tunnel is just a transport.
