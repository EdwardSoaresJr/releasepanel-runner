#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() {
    printf '\033[1;34m[managed-deploy-agent]\033[0m %s\n' "$*"
}

fail() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    fail "Run as root: sudo bash scripts/install.sh"
fi

command -v node >/dev/null 2>&1 || fail "Install Node.js 20+ first (e.g. apt install nodejs or NodeSource)."
command -v npm >/dev/null 2>&1 || fail "npm is required."

node_major="$(node -p "process.versions.node.split('.')[0]")"
if [ "${node_major}" -lt 20 ] 2>/dev/null; then
    fail "Node 20+ required (found $(node --version))."
fi

cd "${RUNNER_DIR}"

export MANAGED_AGENT_TOOLKIT_DIR="${MANAGED_AGENT_TOOLKIT_DIR:-${RUNNER_DIR}/toolkit}"
export RELEASEPANEL_TOOLKIT_DIR="${RELEASEPANEL_TOOLKIT_DIR:-${MANAGED_AGENT_TOOLKIT_DIR}}"

log "Installing npm dependencies."
npm install --omit=dev

if [ ! -f "${RUNNER_DIR}/.env" ]; then
    log "Creating .env from .env.example"
    cp "${RUNNER_DIR}/.env.example" "${RUNNER_DIR}/.env"
fi

RUNNER_ENV_PATH="${RUNNER_DIR}/.env" python3 <<'PY'
import os
from pathlib import Path

env_path = Path(os.environ["RUNNER_ENV_PATH"])
updates = {
    "MANAGED_AGENT_TOOLKIT_DIR": os.environ.get("MANAGED_AGENT_TOOLKIT_DIR"),
    "RELEASEPANEL_TOOLKIT_DIR": os.environ.get("RELEASEPANEL_TOOLKIT_DIR"),
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

SERVICE_TARGET="/etc/systemd/system/managed-deploy-agent.service"
UNIT_SRC="${RUNNER_DIR}/systemd/managed-deploy-agent.service"

sed -e "s#__RUNNER_DIR__#${RUNNER_DIR}#g" "${UNIT_SRC}" > "${SERVICE_TARGET}"
chmod 644 "${SERVICE_TARGET}"

log "systemd unit installed: ${SERVICE_TARGET}"
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
    log "Agent service installed but not started (set MANAGED_AGENT_RUNNER_KEY or RELEASEPANEL_RUNNER_KEY in ${RUNNER_DIR}/.env)."
    echo "  Toolkit path defaults to ${RUNNER_DIR}/toolkit when unset."
    echo "  Then: systemctl restart managed-deploy-agent"
    echo ""
    exit 0
fi

if ! grep -qE '^(MANAGED_AGENT_TOOLKIT_DIR|RELEASEPANEL_TOOLKIT_DIR)=.' "${RUNNER_DIR}/.env"; then
    log "WARNING: toolkit dir is not set in .env — deploy scripts may not resolve."
fi

systemctl restart managed-deploy-agent
log "Agent started. journalctl -u managed-deploy-agent -f"
