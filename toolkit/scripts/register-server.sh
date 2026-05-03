#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${TOOLKIT_DIR}/../server.js" ]; then
    RUNNER_ENV="$(cd "${TOOLKIT_DIR}/.." && pwd)/.env"
else
    RUNNER_ENV="${TOOLKIT_DIR}/runner/.env"
fi

fail() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

quote_json() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

[ "$(id -u)" -eq 0 ] || fail "Run this script as root."

panel_url="${1:-${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}}"
[ -n "${panel_url}" ] || fail "Usage: ${0##*/} <control-plane-url> [server-name] [runner-url]"
panel_url="${panel_url%/}"
server_name="${2:-${MANAGED_AGENT_SERVER_NAME:-${RELEASEPANEL_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}}}"
public_ip="$(curl -fsS https://api.ipify.org 2>/dev/null || curl -fsS https://ifconfig.me 2>/dev/null || true)"
runner_url="${3:-${MANAGED_AGENT_RUNNER_PUBLIC_URL:-${RELEASEPANEL_RUNNER_PUBLIC_URL:-http://127.0.0.1:9000}}}"
runner_key="${MANAGED_AGENT_RUNNER_KEY:-${RELEASEPANEL_RUNNER_KEY:-}}"
server_id="${MANAGED_AGENT_SERVER_ID:-${RELEASEPANEL_SERVER_ID:-}}"

if [ -z "${runner_key}" ] && [ -f "${RUNNER_ENV}" ]; then
    runner_key="$(grep -E '^MANAGED_AGENT_RUNNER_KEY=.' "${RUNNER_ENV}" | tail -n 1 | cut -d= -f2- || true)"
fi
if [ -z "${runner_key}" ] && [ -f "${RUNNER_ENV}" ]; then
    runner_key="$(grep -E '^RELEASEPANEL_RUNNER_KEY=.' "${RUNNER_ENV}" | tail -n 1 | cut -d= -f2- || true)"
fi

if [ -z "${runner_key}" ] || [ "${runner_key}" = "CHANGE_ME" ]; then
    runner_key="$(openssl rand -hex 64)"
fi

install -d -m 0750 "$(dirname "${RUNNER_ENV}")"

if [ -f "${RUNNER_ENV}" ]; then
    cp "${RUNNER_ENV}" "${RUNNER_ENV}.$(date +%Y%m%d%H%M%S).bak"
fi

touch "${RUNNER_ENV}"
chmod 600 "${RUNNER_ENV}"

upsert_env() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "${RUNNER_ENV}"; then
        sed -i -E "s#^${key}=.*#${key}=${value}#" "${RUNNER_ENV}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${RUNNER_ENV}"
    fi
}

upsert_env MANAGED_AGENT_RUNNER_HOST "${MANAGED_AGENT_RUNNER_HOST:-${RELEASEPANEL_RUNNER_HOST:-127.0.0.1}}"
upsert_env RELEASEPANEL_RUNNER_HOST "${RELEASEPANEL_RUNNER_HOST:-${MANAGED_AGENT_RUNNER_HOST:-127.0.0.1}}"
upsert_env MANAGED_AGENT_RUNNER_PORT "9000"
upsert_env RELEASEPANEL_RUNNER_PORT "9000"
upsert_env MANAGED_AGENT_RUNNER_KEY "${runner_key}"
upsert_env RELEASEPANEL_RUNNER_KEY "${runner_key}"
upsert_env MANAGED_AGENT_RUNNER_LOG "/var/log/managed-deploy-agent.log"
upsert_env RELEASEPANEL_RUNNER_LOG "/var/log/managed-deploy-agent.log"
upsert_env MANAGED_AGENT_RUNNER_NORMAL_TIMEOUT_MS "120000"
upsert_env RELEASEPANEL_RUNNER_NORMAL_TIMEOUT_MS "120000"
upsert_env MANAGED_AGENT_RUNNER_DEPLOY_TIMEOUT_MS "900000"
upsert_env RELEASEPANEL_RUNNER_DEPLOY_TIMEOUT_MS "900000"
upsert_env MANAGED_AGENT_PANEL_URL "${panel_url}"
upsert_env RELEASEPANEL_PANEL_URL "${panel_url}"
upsert_env MANAGED_AGENT_RUNNER_PUBLIC_URL "${runner_url}"
upsert_env RELEASEPANEL_RUNNER_PUBLIC_URL "${runner_url}"
upsert_env MANAGED_AGENT_RUNNER_HEARTBEAT_MS "30000"
upsert_env RELEASEPANEL_RUNNER_HEARTBEAT_MS "30000"

case "${MANAGED_AGENT_REGISTER_INSECURE_TLS:-${RELEASEPANEL_REGISTER_INSECURE_TLS:-}}" in
    1 | true | TRUE | yes | YES | on | ON)
        upsert_env MANAGED_AGENT_PANEL_INSECURE_TLS "1"
        upsert_env RELEASEPANEL_PANEL_INSECURE_TLS "1"
        ;;
esac

payload="$(printf '{"name":%s,"public_ip":%s,"runner_url":%s,"server_id":%s}' \
    "$(quote_json "${server_name}")" \
    "$(quote_json "${public_ip:-unknown}")" \
    "$(quote_json "${runner_url}")" \
    "$(quote_json "${server_id}")")"

echo "[managed-deploy-agent] Runner key written to ${RUNNER_ENV}."

echo "[managed-deploy-agent] Registering this server with the control plane."

curl_opts=(-fsS)
case "${MANAGED_AGENT_REGISTER_INSECURE_TLS:-${RELEASEPANEL_REGISTER_INSECURE_TLS:-}}" in
    1 | true | TRUE | yes | YES | on | ON)
        curl_opts+=(-k)
        echo "[managed-deploy-agent] WARNING: insecure TLS enabled for this registration request (staging/self-signed only)." >&2
        ;;
esac

curl "${curl_opts[@]}" -X POST "${panel_url}/api/register-runner" \
    -H "X-RUNNER-KEY: ${runner_key}" \
    -H "Content-Type: application/json" \
    -d "${payload}"

echo
echo "[managed-deploy-agent] Registration complete."
