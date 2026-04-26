# Contributing

Issues and PRs welcome. This setup was built for one person's workflow, so there are rough edges when you try it on different environments.

## Good PRs

- Fixes for edge cases on different WSL distros
- Support for other identity providers in Access docs (Okta, Azure AD, GitHub)
- Troubleshooting entries for new failure modes you hit
- Better automation of Step 5 (Cloudflare Access setup) — currently manual dashboard clicks

## Before opening an issue

1. Check [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — your problem might already be there
2. Include:
   - Windows version (`winver`)
   - WSL distro and version (`wsl --version`, `wsl -d <distro> -e lsb_release -a`)
   - code-server version (`code-server --version`)
   - cloudflared version (`cloudflared --version`)
   - Relevant logs from `E:\code\remote-vscode-wsl-cloudflare\logs\startup.log`, `E:\code\remote-vscode-wsl-cloudflare\logs\health-check.log`, and `/tmp/code-server.log`

## Security disclosures

If you find a security issue in this setup (not in upstream code-server / cloudflared — report those to the respective projects), please open a private issue or email rather than a public issue.
