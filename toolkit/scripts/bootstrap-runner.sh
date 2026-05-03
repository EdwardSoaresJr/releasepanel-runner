#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "[bootstrap-runner] ERROR: Run this script as root." >&2
    exit 1
fi

bash "${SCRIPT_DIR}/assert-fresh-managed-server.sh"

echo "[bootstrap-runner] Installing managed-server runtime only."

RELEASEPANEL_SKIP_APP_BOOTSTRAP=true bash "${SCRIPT_DIR}/01-bootstrap.sh"

PANEL_URL="${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}"
if [ -n "${PANEL_URL}" ]; then
    # Uses connectivity probe; auto-sets insecure TLS only when verify fails with curl SSL exit 60/51 (see join-panel.sh).
    bash "${SCRIPT_DIR}/join-panel.sh" "${PANEL_URL}"
fi

bash "${SCRIPT_DIR}/install-runner.sh"

echo "[bootstrap-runner] Managed Deploy Agent standalone bootstrap complete."
echo "[bootstrap-runner] Operator CLI: managed-deploy (releasepanel symlink is not installed on managed-agent-only hosts)."
echo "[bootstrap-runner] COMPLETE"
