#!/bin/bash
# ============================================================================
# start-code-server.sh — Launch code-server inside WSL
# ----------------------------------------------------------------------------
# Place at: /home/<user>/start-code-server.sh   (chmod +x it)
#
# Called by auto-start.ps1 on Windows at logon, or manually when you want
# to restart code-server inside WSL.
#
# Why EXTENSIONS_GALLERY is set here:
#   code-server 4.x no longer ships a default extensions marketplace URL
#   baked into product.json. Without this export, the Extensions pane shows
#   POPULAR: 0 and RECOMMENDED: 0 even though code-server is working fine.
#   Pointing it at Open VSX fixes search, install, Popular, and Recommended
#   in one shot. Open VSX is the default registry for all VS Code forks
#   (Gitpod, Theia, code-server, etc.) and is free to use.
# ============================================================================

PORT=8081
PROJECT_DIR=/mnt/e/code   # Root directory that opens when you connect

echo "[WSL] Starting code-server..."

# Kill anything holding the port from a previous session
fuser -k ${PORT}/tcp 2>/dev/null
sleep 2

# Point code-server at Open VSX — fixes the empty-marketplace bug on 4.x
export EXTENSIONS_GALLERY='{"serviceUrl":"https://open-vsx.org/vscode/gallery","itemUrl":"https://open-vsx.org/vscode/item","resourceUrlTemplate":"https://openvsxorg.blob.core.windows.net/resources/{publisher}/{name}/{version}/{path}"}'

# Launch detached from any parent shell so the PS1 invocation returns cleanly.
# stdout/stderr go to /tmp/code-server.log for debugging.
setsid code-server \
  --bind-addr 0.0.0.0:${PORT} \
  "${PROJECT_DIR}" \
  > /tmp/code-server.log 2>&1 < /dev/null &

sleep 2

# Verify it actually bound to the port
if ss -tulnp | grep -q ${PORT}; then
    echo "[WSL] code-server is LISTENING on ${PORT}"
else
    echo "[WSL] ERROR: code-server not listening"
    echo "Check log: /tmp/code-server.log"
    exit 1
fi
