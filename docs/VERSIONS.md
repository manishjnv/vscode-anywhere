# Versions

Known-good versions of every component in the stack. Bump deliberately, never via blanket auto-update (`winget upgrade --all`, code-server extension auto-update, etc.). When a component is updated, replace the row, add a one-line note under "Bump log" with the date and reason.

## Baseline (captured 2026-05-13)

| Component | Version | How to check |
|---|---|---|
| **Windows** | 10.0.26200.8246 (Windows 11 Pro) | `(Get-CimInstance Win32_OperatingSystem).Version` |
| **PowerShell** (Task Scheduler) | 5.1.26100.81 | `powershell -Command '$PSVersionTable.PSVersion'` |
| **PowerShell** (interactive) | 7.5.5 | `pwsh -Command '$PSVersionTable.PSVersion'` |
| **WSL** | 2.7.3.0 | `wsl --version` |
| **WSL kernel** | 6.6.114.1-1 | `wsl --version` |
| **Distro** | Ubuntu (default) | `wsl -l -v` |
| **code-server** | 4.116.0 (Code 1.116.0) | `wsl -u admin -e code-server --version` |
| **cloudflared** | 2025.8.1 | `cloudflared --version` |

## Why pinning matters

- **cloudflared** -- past releases have broken `originRequest` keys, changed `--config` parsing, and shipped Windows-specific QUIC regressions. A `winget upgrade` that hits cloudflared at 3 AM is exactly when you don't want to debug a tunnel daemon.
- **code-server** -- minor versions occasionally change extension API surface; an extension that worked yesterday may crash the extension host today.
- **WSL kernel** -- Windows updates can bump it silently. Mostly stable, but `networkingMode` defaults have changed across kernels (see [RCA-009](RCA.md)).
- **Extensions inside code-server** -- auto-update disabled via `extensions.autoUpdate: false` / `extensions.autoCheckUpdates: false` in user settings. Update by hand from the Extensions sidebar when you specifically want to.

## Bump log

Newest first.

- **2026-05-13** -- Baseline captured. No version changes; this file documents the current state as the known-good reference.
