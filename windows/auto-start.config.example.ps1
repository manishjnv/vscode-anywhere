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
