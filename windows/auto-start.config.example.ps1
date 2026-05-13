# ============================================================================
# auto-start.config.example.ps1 -- TEMPLATE for the local config file
# ----------------------------------------------------------------------------
# Copy this to the path referenced by $ConfigPath in auto-start.ps1
# (default: E:\code\auto-start.config.ps1) and fill in your real values.
#
# This file is a TEMPLATE and is committed to git. The copy with real values
# is .gitignored -- see .gitignore for the rule.
# ============================================================================

# These variables are dot-sourced into auto-start.ps1 -- the linter cannot
# see the cross-file consumption, so suppress the "assigned but never used"
# rule. (Without param() the attribute would have nothing to attach to.)
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Dot-sourced into auto-start.ps1 which consumes these.')]
param()

$WSL_USER    = "admin"               # WSL user that owns code-server
$WSL_DISTRO  = "Ubuntu"              # `wsl -l -v` to list installed distros (set "" to use default)
$PORT        = 8081                  # Port code-server binds to in WSL
$TUNNEL      = "dev-tunnel"          # cloudflared tunnel name
$PUBLIC_HOST = "dev.yourdomain.com"  # The hostname you routed to this tunnel
$LOG         = "E:\code\remote-vscode-wsl-cloudflare\logs\startup.log" # PowerShell transcript; health-check.log lands in the same dir

# Optional: Healthchecks.io (or compatible) dead-man's-switch ping URL.
# Sign up free at https://healthchecks.io, create a check with Period=5min,
# Grace=1min, copy the "Ping URL" here. health-check.ps1 pings it every
# cycle on OK/RECOVERED and pings <url>/fail on STILL UNHEALTHY. If no ping
# arrives for >6 minutes Healthchecks emails you. This covers everything the
# local watchdog cannot self-detect: laptop dead, network out, Task Scheduler
# disabled, watchdog itself crashed. Leave as $null to disable.
$HEALTHCHECK_URL = $null
