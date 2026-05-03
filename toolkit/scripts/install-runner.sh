#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Classic layout: <toolkit>/runner/ (private deploy checkout). Public bundle: <repo>/toolkit + <repo>/server.js.
if [ -f "${TOOLKIT_DIR}/../server.js" ]; then
    RUNNER_DIR="$(cd "${TOOLKIT_DIR}/.." && pwd)"
else
    RUNNER_DIR="${TOOLKIT_DIR}/runner"
fi
SERVICE_SOURCE="${TOOLKIT_DIR}/systemd/managed-deploy-agent.service.example"
SERVICE_TARGET="/etc/systemd/system/managed-deploy-agent.service"

log() {
    printf '\033[1;34m[deploy-toolkit]\033[0m %s\n' "$*"
}

fail() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    fail "Run this script as root."
fi

command -v node >/dev/null 2>&1 || fail "node is not installed."
command -v npm >/dev/null 2>&1 || fail "npm is not installed."

cd "${RUNNER_DIR}"

log "Installing agent dependencies."
npm install --omit=dev

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
if [ -f "${RUNNER_DIR}/systemd/managed-deploy-agent.service" ]; then
    sed -e "s#__RUNNER_DIR__#${RUNNER_DIR}#g" "${RUNNER_DIR}/systemd/managed-deploy-agent.service" > "${SERVICE_TARGET}"
else
    sed \
        -e "s#__RELEASEPANEL_TOOLKIT_DIR__#${TOOLKIT_DIR}#g" \
        -e "s#/opt/releasepanel-deploy#${TOOLKIT_DIR}#g" \
        "${SERVICE_SOURCE}" > "${SERVICE_TARGET}"
fi

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

echo ""
echo "[deploy-toolkit] Agent installed."
echo "Next steps:"
echo "  nano ${RUNNER_DIR}/.env"
echo "  confirm runner key is set"
echo "  systemctl status managed-deploy-agent --no-pager"
echo ""
