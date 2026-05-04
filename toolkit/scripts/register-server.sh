#!/usr/bin/env bash
# Registers this host with the panel (POST /api/register-runner) and writes agent .env only after success.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNNER_HOME="$(
    export RELEASEPANEL_TOOLKIT_DIR="${TOOLKIT_DIR}"
    export RELEASEPANEL_RUNNER_DIR="${RELEASEPANEL_RUNNER_DIR:-}"
    # shellcheck source=../lib/common.sh
    . "${TOOLKIT_DIR}/lib/common.sh"
    releasepanel_resolve_runner_directory
)"
RUNNER_ENV="${RUNNER_HOME}/.env"

fail() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

# Print panel JSON (code/message/hint) to stderr; works for install-key and other registration errors.
registration_error_to_stderr() {
    local http_code="$1"
    local body="$2"
    printf '%s' "${body}" | python3 -c '
import json, sys
http = sys.argv[1]
raw = sys.stdin.read()
print("", file=sys.stderr)
print("\033[1;31m[managed-deploy-agent] Registration rejected by the control plane\033[0m", file=sys.stderr)
print(f"  HTTP: {http}", file=sys.stderr)
try:
    j = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    print("  (response was not JSON — full body below)", file=sys.stderr)
    print(raw[:4000] if raw else "(empty)", file=sys.stderr)
    sys.exit(0)
code = j.get("code") or ""
msg = j.get("message") or ""
hint = j.get("hint") or ""
if code:
    print(f"  code: {code}", file=sys.stderr)
if msg:
    print(f"  message: {msg}", file=sys.stderr)
if hint:
    print(f"  hint: {hint}", file=sys.stderr)
guides = {
    "install_key_invalid": "Install key is wrong or unknown. In ReleasePanel: copy the current key from Connect server / Settings, or Rotate Install Key and use the new key.",
    "install_key_exhausted": "This install key was already used (single-use). Rotate Install Key in ReleasePanel, then re-run install or: managed-deploy join <panel-url> --account-key=<NEW_KEY>",
    "install_key_expired": "Install key expired. Rotate Install Key in ReleasePanel and try again.",
    "account_install_key_required": "Panel requires an install key but none was sent. Pass --account-key= on install or export MANAGED_AGENT_ACCOUNT_KEY before join.",
    "account_install_key_mismatch": "Key does not match this account. Confirm you copied the key for the correct organization.",
}
g = guides.get(code)
if g:
    print("", file=sys.stderr)
    print("  → " + g, file=sys.stderr)
elif raw.strip() and not code:
    print("", file=sys.stderr)
    print("  raw: " + raw[:800], file=sys.stderr)
' "${http_code}" || true
}

quote_json() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

[ "$(id -u)" -eq 0 ] || fail "Run this script as root."

panel_url="${1:-${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}}"
[ -n "${panel_url}" ] || fail "Usage: ${0##*/} <control-plane-url> [server-name] [runner-url]"
panel_url="${panel_url%/}"
server_name="${2:-${MANAGED_AGENT_SERVER_NAME:-${RELEASEPANEL_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}}}"
reported_hostname="$(hostname -f 2>/dev/null || hostname)"
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
    runner_key="$(openssl rand -hex 32)"
fi

# Self-signed HTTPS panel: only mirror join-panel auto-insecure when curl fails *certificate verification* (60/51),
# not transient connection errors during nginx reload (those must not write MANAGED_AGENT_PANEL_INSECURE_TLS=1).
if [ -z "${MANAGED_AGENT_REGISTER_INSECURE_TLS:-}" ] && [ -z "${RELEASEPANEL_REGISTER_INSECURE_TLS:-}" ]; then
    case "${MANAGED_AGENT_DISABLE_AUTO_INSECURE_TLS:-${RELEASEPANEL_DISABLE_AUTO_INSECURE_TLS:-}}" in
        1 | true | TRUE | yes | YES | on | ON)
            ;;
        *)
            case "${panel_url}" in
                https://*)
                    check_url="${panel_url%/}/api/runner-connectivity-check"
                    set +e
                    curl -fsS --connect-timeout 15 --max-time 30 "${check_url}" >/dev/null 2>&1
                    curl_ev=$?
                    set -e
                    if [ "${curl_ev}" -eq 60 ] || [ "${curl_ev}" -eq 51 ]; then
                        set +e
                        curl -fsSk --connect-timeout 15 --max-time 30 "${check_url}" >/dev/null 2>&1
                        curl_k_ev=$?
                        set -e
                        if [ "${curl_k_ev}" -eq 0 ]; then
                            MANAGED_AGENT_REGISTER_INSECURE_TLS=1
                            RELEASEPANEL_REGISTER_INSECURE_TLS=1
                            printf '%s\n' "[managed-deploy-agent] TLS verify failed (curl exit ${curl_ev}); enabling MANAGED_AGENT_REGISTER_INSECURE_TLS for registration and agent .env." >&2
                        fi
                    fi
                    ;;
            esac
            ;;
    esac
fi

install -d -m 0750 "$(dirname "${RUNNER_ENV}")"

if [ -f "${RUNNER_ENV}" ]; then
    cp "${RUNNER_ENV}" "${RUNNER_ENV}.$(date +%Y%m%d%H%M%S).bak"
fi

# Read from the environment for this registration request only — never written to the agent .env
# (account key is onboarding-only; runner key is long-term auth).
panel_install_key="${MANAGED_AGENT_ACCOUNT_KEY:-${RELEASEPANEL_AGENT_ACCOUNT_KEY:-${MANAGED_AGENT_PANEL_INSTALL_KEY:-${RELEASEPANEL_INSTALL_KEY:-${RELEASEPANEL_PANEL_INSTALL_KEY:-}}}}}"

# Default outbound poll on: Prepare server, deploy, site create, SSL use POST /api/agent/poll.
poll_raw="${MANAGED_AGENT_POLL_ENABLED:-${RELEASEPANEL_POLL_ENABLED:-}}"
if [ -z "${poll_raw}" ]; then
    poll_raw=true
fi
poll_enabled_write=true
case "${poll_raw}" in
    0 | false | FALSE | no | NO | off | OFF)
        poll_enabled_write=false
        ;;
esac

# reg_complete: 1 = final env after POST /api/register-runner (strip install key); 0 = staging so a
# concurrently running agent can heartbeat-bootstrap with the install key before curl returns.
write_runner_env() {
    local rk="$1"
    local reg_complete="$2"
    local tmp
    tmp="$(mktemp)"
    chmod 600 "${tmp}" 2>/dev/null || true
    {
        printf 'MANAGED_AGENT_RUNNER_HOST=%s\n' "${MANAGED_AGENT_RUNNER_HOST:-${RELEASEPANEL_RUNNER_HOST:-127.0.0.1}}"
        printf 'RELEASEPANEL_RUNNER_HOST=%s\n' "${RELEASEPANEL_RUNNER_HOST:-${MANAGED_AGENT_RUNNER_HOST:-127.0.0.1}}"
        printf 'MANAGED_AGENT_RUNNER_PORT=9000\n'
        printf 'RELEASEPANEL_RUNNER_PORT=9000\n'
        printf 'MANAGED_AGENT_RUNNER_KEY=%s\n' "${rk}"
        printf 'RELEASEPANEL_RUNNER_KEY=%s\n' "${rk}"
        printf 'MANAGED_AGENT_RUNNER_LOG=/var/log/managed-deploy-agent.log\n'
        printf 'RELEASEPANEL_RUNNER_LOG=/var/log/managed-deploy-agent.log\n'
        printf 'MANAGED_AGENT_RUNNER_NORMAL_TIMEOUT_MS=120000\n'
        printf 'RELEASEPANEL_RUNNER_NORMAL_TIMEOUT_MS=120000\n'
        printf 'MANAGED_AGENT_RUNNER_DEPLOY_TIMEOUT_MS=900000\n'
        printf 'RELEASEPANEL_RUNNER_DEPLOY_TIMEOUT_MS=900000\n'
        printf 'MANAGED_AGENT_PANEL_URL=%s\n' "${panel_url}"
        printf 'RELEASEPANEL_PANEL_URL=%s\n' "${panel_url}"
        printf 'MANAGED_AGENT_RUNNER_PUBLIC_URL=%s\n' "${runner_url}"
        printf 'RELEASEPANEL_RUNNER_PUBLIC_URL=%s\n' "${runner_url}"
        printf 'MANAGED_AGENT_RUNNER_HEARTBEAT_MS=30000\n'
        printf 'RELEASEPANEL_RUNNER_HEARTBEAT_MS=30000\n'
        printf 'MANAGED_AGENT_SERVER_NAME=%s\n' "${server_name}"
        printf 'RELEASEPANEL_SERVER_NAME=%s\n' "${server_name}"
        if [ "${poll_enabled_write}" = true ]; then
            printf 'MANAGED_AGENT_POLL_ENABLED=true\n'
            printf 'RELEASEPANEL_POLL_ENABLED=true\n'
        else
            printf 'MANAGED_AGENT_POLL_ENABLED=false\n'
            printf 'RELEASEPANEL_POLL_ENABLED=false\n'
        fi
        if [ "${reg_complete}" = "1" ]; then
            printf 'MANAGED_AGENT_REGISTRATION_COMPLETE=1\n'
            printf 'RELEASEPANEL_REGISTRATION_COMPLETE=1\n'
        else
            printf 'MANAGED_AGENT_REGISTRATION_COMPLETE=0\n'
            printf 'RELEASEPANEL_REGISTRATION_COMPLETE=0\n'
        fi
        case "${MANAGED_AGENT_REGISTER_INSECURE_TLS:-${RELEASEPANEL_REGISTER_INSECURE_TLS:-}}" in
            1 | true | TRUE | yes | YES | on | ON)
                printf 'MANAGED_AGENT_PANEL_INSECURE_TLS=1\n'
                printf 'RELEASEPANEL_PANEL_INSECURE_TLS=1\n'
                ;;
        esac
        if [ "${reg_complete}" != "1" ] && [ -n "${panel_install_key}" ]; then
            printf 'MANAGED_AGENT_ACCOUNT_KEY=%s\n' "${panel_install_key}"
            printf 'RELEASEPANEL_PANEL_INSTALL_KEY=%s\n' "${panel_install_key}"
        fi
    } > "${tmp}"
    mv -f "${tmp}" "${RUNNER_ENV}"
    chmod 600 "${RUNNER_ENV}"

    if [ "${reg_complete}" = "1" ]; then
        sed -i \
            -e '/^MANAGED_AGENT_ACCOUNT_KEY=/d' \
            -e '/^RELEASEPANEL_AGENT_ACCOUNT_KEY=/d' \
            -e '/^MANAGED_AGENT_PANEL_INSTALL_KEY=/d' \
            -e '/^RELEASEPANEL_INSTALL_KEY=/d' \
            -e '/^RELEASEPANEL_PANEL_INSTALL_KEY=/d' \
            "${RUNNER_ENV}" 2>/dev/null || true
    fi
}

payload="$(printf '{"name":%s,"hostname":%s,"public_ip":%s,"runner_url":%s,"server_id":%s}' \
    "$(quote_json "${server_name}")" \
    "$(quote_json "${reported_hostname}")" \
    "$(quote_json "${public_ip:-unknown}")" \
    "$(quote_json "${runner_url}")" \
    "$(quote_json "${server_id}")")"

case "${runner_url}" in
    http://127.0.0.1* | http://localhost* | https://127.0.0.1* | https://localhost*)
        printf '%s\n' "[managed-deploy-agent] WARN: runner_url is ${runner_url}. The hosted panel cannot open that address from its own network. Set MANAGED_AGENT_RUNNER_PUBLIC_URL (tunnel, VPN URL, or http(s)://YOUR_PUBLIC_IP:9000 with bind 0.0.0.0 + firewall allowlist) then restart the agent. See docs/agent-panel-connection.md." >&2
        ;;
esac

write_runner_env "${runner_key}" 0

printf '%s\n' "[managed-deploy-agent] Registering with control plane (staging ${RUNNER_ENV} with REGISTRATION_COMPLETE=0 so a running agent can heartbeat during join)…"

reg_hdrs=()
case "${MANAGED_AGENT_REGISTER_INSECURE_TLS:-${RELEASEPANEL_REGISTER_INSECURE_TLS:-}}" in
    1 | true | TRUE | yes | YES | on | ON)
        reg_hdrs+=(-k)
        echo "[managed-deploy-agent] WARNING: insecure TLS enabled for this registration request (private CA / untrusted panel certificate only)." >&2
        ;;
esac
if [ -n "${panel_install_key}" ]; then
    reg_hdrs+=(-H "X-ACCOUNT-INSTALL-KEY: ${panel_install_key}")
    reg_hdrs+=(-H "X-RELEASEPANEL-INSTALL-KEY: ${panel_install_key}")
fi

tmp_body="$(mktemp)"
trap 'rm -f "${tmp_body}"' EXIT

do_register() {
    local use_key="$1"
    local ts sig canonical
    ts="$(date +%s)"
    canonical="$(printf '%s\n%s' "${ts}" "${payload}")"
    sig="$(printf '%s' "${canonical}" | openssl dgst -sha256 -hmac "${use_key}" 2>/dev/null | awk '{print $NF}')"
    if [ -z "${sig}" ]; then
        fail "Could not compute runner request signature (openssl HMAC). Install OpenSSL."
    fi
    curl -sS "${reg_hdrs[@]}" -o "${tmp_body}" -w '%{http_code}' -X POST "${panel_url}/api/register-runner" \
        -H "X-RUNNER-KEY: ${use_key}" \
        -H "X-Runner-Timestamp: ${ts}" \
        -H "X-Runner-Signature: ${sig}" \
        -H "Content-Type: application/json" \
        -d "${payload}"
}

http_code="$(do_register "${runner_key}")"
body="$(cat "${tmp_body}")"

if [ "${http_code}" = "409" ]; then
    if printf '%s' "${body}" | python3 -c "import json,sys; j=json.load(sys.stdin); raise SystemExit(0 if j.get('code')=='runner_key_host_mismatch' and j.get('regenerate_runner_key') else 1)" 2>/dev/null; then
        printf '%s\n' "[managed-deploy-agent] Runner key is already bound to another host; generating a fresh key on this VPS and retrying registration once." >&2
        runner_key="$(openssl rand -hex 32)"
        write_runner_env "${runner_key}" 0
        http_code="$(do_register "${runner_key}")"
        body="$(cat "${tmp_body}")"
    fi
fi

case "${http_code}" in
    2[0-9][0-9])
        printf '%s\n' "${body}"
        write_runner_env "${runner_key}" 1
        printf '%s\n' "[managed-deploy-agent] Wrote ${RUNNER_ENV} and registration complete."
        ;;
    *)
        registration_error_to_stderr "${http_code}" "${body}"
        fail "Registration failed (HTTP ${http_code}). See the details above (especially code: install_key_*)."
        ;;
esac
