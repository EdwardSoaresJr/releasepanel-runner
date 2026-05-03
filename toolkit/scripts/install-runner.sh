#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export RELEASEPANEL_TOOLKIT_DIR="${TOOLKIT_DIR}"

# shellcheck source=../lib/common.sh
. "${TOOLKIT_DIR}/lib/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    fail "Run this script as root."
fi

command -v node >/dev/null 2>&1 || fail "node is not installed."
command -v npm >/dev/null 2>&1 || fail "npm is not installed."

RUNNER_DIR="$(releasepanel_resolve_runner_directory)"

cd "${RUNNER_DIR}"

log "Installing agent dependencies (${RUNNER_DIR})."
releasepanel_managed_agent_install_node_modules "${RUNNER_DIR}" || fail "npm install failed."

if [ ! -f "${RUNNER_DIR}/.env" ]; then
    log "Creating .env from .env.example."
    cp "${RUNNER_DIR}/.env.example" "${RUNNER_DIR}/.env"
fi

export MANAGED_AGENT_TOOLKIT_DIR_EFFECTIVE="${MANAGED_AGENT_TOOLKIT_DIR:-${RELEASEPANEL_TOOLKIT_DIR:-${TOOLKIT_DIR}}}"
export RELEASEPANEL_TOOLKIT_DIR_EFFECTIVE="${RELEASEPANEL_TOOLKIT_DIR:-${MANAGED_AGENT_TOOLKIT_DIR_EFFECTIVE}}"

RUNNER_ENV_PATH="${RUNNER_DIR}/.env" python3 <<'PY'
import os
from pathlib import Path

env_path = Path(os.environ["RUNNER_ENV_PATH"])
updates = {
    "MANAGED_AGENT_TOOLKIT_DIR": os.environ.get("MANAGED_AGENT_TOOLKIT_DIR_EFFECTIVE"),
    "RELEASEPANEL_TOOLKIT_DIR": os.environ.get("RELEASEPANEL_TOOLKIT_DIR_EFFECTIVE"),
    "MANAGED_AGENT_RUNNER_HOST": os.environ.get("MANAGED_AGENT_RUNNER_HOST"),
    "RELEASEPANEL_RUNNER_HOST": os.environ.get("RELEASEPANEL_RUNNER_HOST"),
    "MANAGED_AGENT_RUNNER_PORT": os.environ.get("MANAGED_AGENT_RUNNER_PORT"),
    "RELEASEPANEL_RUNNER_PORT": os.environ.get("RELEASEPANEL_RUNNER_PORT"),
    "MANAGED_AGENT_RUNNER_KEY": os.environ.get("MANAGED_AGENT_RUNNER_KEY"),
    "RELEASEPANEL_RUNNER_KEY": os.environ.get("RELEASEPANEL_RUNNER_KEY"),
    "MANAGED_AGENT_RUNNER_LOG": os.environ.get("MANAGED_AGENT_RUNNER_LOG"),
    "RELEASEPANEL_RUNNER_LOG": os.environ.get("RELEASEPANEL_RUNNER_LOG"),
    "MANAGED_AGENT_PANEL_URL": os.environ.get("MANAGED_AGENT_PANEL_URL"),
    "RELEASEPANEL_PANEL_URL": os.environ.get("RELEASEPANEL_PANEL_URL"),
    "MANAGED_AGENT_RUNNER_PUBLIC_URL": os.environ.get("MANAGED_AGENT_RUNNER_PUBLIC_URL"),
    "RELEASEPANEL_RUNNER_PUBLIC_URL": os.environ.get("RELEASEPANEL_RUNNER_PUBLIC_URL"),
}
updates = {key: value for key, value in updates.items() if value}

if updates:
    lines = env_path.read_text().splitlines()
    seen = set()
    rewritten = []

    for line in lines:
        key = line.split("=", 1)[0] if "=" in line else ""

        if key in updates:
            rewritten.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            rewritten.append(line)

    for key, value in updates.items():
        if key not in seen:
            rewritten.append(f"{key}={value}")

    env_path.write_text("\n".join(rewritten).rstrip() + "\n")
PY

chmod 600 "${RUNNER_DIR}/.env"

log "Installing systemd service."
releasepanel_write_managed_agent_systemd_unit "${RUNNER_DIR}" "${TOOLKIT_DIR}" || fail "Could not write systemd unit."

systemctl daemon-reload
systemctl enable managed-deploy-agent

runner_key_ok=0
if grep -qE '^MANAGED_AGENT_RUNNER_KEY=.' "${RUNNER_DIR}/.env" 2>/dev/null && ! grep -q '^MANAGED_AGENT_RUNNER_KEY=CHANGE_ME$' "${RUNNER_DIR}/.env"; then
    runner_key_ok=1
fi
if grep -qE '^RELEASEPANEL_RUNNER_KEY=.' "${RUNNER_DIR}/.env" 2>/dev/null && ! grep -q '^RELEASEPANEL_RUNNER_KEY=CHANGE_ME$' "${RUNNER_DIR}/.env"; then
    runner_key_ok=1
fi

if [ "${runner_key_ok}" -eq 0 ]; then
    echo ""
    echo "[deploy-toolkit] Agent service installed but not started."
    echo "Next steps:"
    echo "  nano ${RUNNER_DIR}/.env"
    echo "  set MANAGED_AGENT_RUNNER_KEY (or legacy RELEASEPANEL_RUNNER_KEY) to a strong secret"
    echo "  systemctl restart managed-deploy-agent"
    echo ""
    exit 0
fi

systemctl restart managed-deploy-agent

log "Verifying managed deploy agent /health (matching panel RELEASEPANEL_RUNNER_KEY)..."
if ! releasepanel_runner_probe_health "${RUNNER_DIR}" 90; then
    systemctl status managed-deploy-agent --no-pager || true
    journalctl -u managed-deploy-agent -n 80 --no-pager || true
    fail "Managed deploy agent did not become healthy. Fix errors above, then: sudo releasepanel runner"
fi

echo ""
echo "[deploy-toolkit] Agent installed."
echo "Next steps:"
echo "  nano ${RUNNER_DIR}/.env"
echo "  confirm runner key is set"
echo "  systemctl status managed-deploy-agent --no-pager"
echo ""
