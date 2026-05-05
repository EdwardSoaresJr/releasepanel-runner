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
    "install_key_invalid": "The panel received a full key that does not match your org (hash lookup failed). Open Settings → Rotate or copy the current install key, paste with no spaces or line breaks, and retry. If this copy was from Word/Slack/email, re-copy from the browser (CRLF and hidden characters cause this).",
    "runner_url_loopback_rejected": "Your installer is stale or still sending 127.0.0.1 as runner_url. On the VPS: cd /opt/managed-deploy-agent && git pull && git -C toolkit pull origin main (or reinstall), then retry join — or upgrade app.releasepanel.com to the latest releasepanel-app.",
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
panel_url_lc="$(printf '%s' "${panel_url}" | tr '[:upper:]' '[:lower:]')"

# SaaS/hosted URLs cannot POST back to localhost on the agent — used to ignore stale 127.0.0.1 in env while still allowing self-hosted LAN panels.
hosted_panel_expects_routable_runner_url=false
case "${panel_url_lc}" in
    https://*)
        hosted_panel_expects_routable_runner_url=true
        case "${panel_url_lc}" in
            https://localhost* | https://127.0.0.1* | https://\[::1\]* | https://::1* | https://[::1]*)
                hosted_panel_expects_routable_runner_url=false
                ;;
        esac
        ;;
    http://*)
        case "${panel_url_lc}" in
            http://localhost* | http://127.0.0.1* | http://\[::1\]* | http://::1* | http://[::1]*)
                ;;
            *)
                hosted_panel_expects_routable_runner_url=true
                ;;
        esac
        ;;
esac

releasepanel_is_loopback_agent_runner_url() {
    local lc
    lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "${lc}" in
        '') return 1 ;;
        http://127.0.0.1* | http://localhost* | https://127.0.0.1* | https://localhost*) return 0 ;;
        http://\[::1\]*:* | https://\[::1\]*:* | http://[::1]*:* | https://[::1]*:*) return 0 ;;
        *) return 1 ;;
    esac
}

MANAGED_AGENT_RUNNER_PUBLIC_URL="${MANAGED_AGENT_RUNNER_PUBLIC_URL:-}"
RELEASEPANEL_RUNNER_PUBLIC_URL="${RELEASEPANEL_RUNNER_PUBLIC_URL:-}"
MANAGED_AGENT_RUNNER_PUBLIC_URL="${MANAGED_AGENT_RUNNER_PUBLIC_URL//$'\r'/}"
RELEASEPANEL_RUNNER_PUBLIC_URL="${RELEASEPANEL_RUNNER_PUBLIC_URL//$'\r'/}"

if [ "${hosted_panel_expects_routable_runner_url}" = true ]; then
    if releasepanel_is_loopback_agent_runner_url "${MANAGED_AGENT_RUNNER_PUBLIC_URL:-}"; then
        printf '%s\n' "[managed-deploy-agent] Ignoring stale loopback MANAGED_AGENT_RUNNER_PUBLIC_URL (${MANAGED_AGENT_RUNNER_PUBLIC_URL}) for hosted HTTPS panel — deriving runner_url from egress IP or omitting from JSON instead." >&2
        MANAGED_AGENT_RUNNER_PUBLIC_URL=""
    fi
    if releasepanel_is_loopback_agent_runner_url "${RELEASEPANEL_RUNNER_PUBLIC_URL:-}"; then
        printf '%s\n' "[managed-deploy-agent] Ignoring stale loopback RELEASEPANEL_RUNNER_PUBLIC_URL (${RELEASEPANEL_RUNNER_PUBLIC_URL})." >&2
        RELEASEPANEL_RUNNER_PUBLIC_URL=""
    fi
fi

server_name="${2:-${MANAGED_AGENT_SERVER_NAME:-${RELEASEPANEL_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}}}"
reported_hostname="$(hostname -f 2>/dev/null || hostname)"

# Agent-side public IPv4 for registration (panel must not infer from TCP source — proxies/CDN break request()->ip()).
# Accept only globally routable IPv4 (Python ipaddress.is_global — excludes 10/8, RFC1918, CGNAT, loopback, etc.).
releasepanel_is_routable_agent_ipv4() {
    python3 -c '
import ipaddress, sys
raw = sys.argv[1].strip()
try:
    addr = ipaddress.ip_address(raw)
except ValueError:
    sys.exit(1)
sys.exit(0 if addr.version == 4 and addr.is_global else 1)
' "$1" 2>/dev/null
}

releasepanel_probe_public_ipv4() {
    printf '%s' "$(
        curl -4fsS --connect-timeout 10 --max-time 20 "${1}" 2>/dev/null || true
    )" | tr -d '[:space:]'
}

runner_explicit=false
if [ -n "${3:-}" ] || [ -n "${MANAGED_AGENT_RUNNER_PUBLIC_URL:-}" ] || [ -n "${RELEASEPANEL_RUNNER_PUBLIC_URL:-}" ]; then
    runner_explicit=true
fi

detected_public_ipv4=""
for _probe_url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://checkip.amazonaws.com" \
    "https://api4.ipify.org" \
    "https://ipv4.icanhazip.com"; do
    candidate="$(releasepanel_probe_public_ipv4 "${_probe_url}")"
    if [ -n "${candidate}" ] && releasepanel_is_routable_agent_ipv4 "${candidate}"; then
        detected_public_ipv4="${candidate}"
        printf '%s\n' "[managed-deploy-agent] Detected public IP for runner_url: ${detected_public_ipv4}" >&2
        break
    fi
done

if [ -z "${detected_public_ipv4}" ]; then
    candidate="$(curl -4fsS --connect-timeout 1 --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)"
    candidate="$(printf '%s' "${candidate}" | tr -d '[:space:]')"
    if [ -n "${candidate}" ] && releasepanel_is_routable_agent_ipv4 "${candidate}"; then
        detected_public_ipv4="${candidate}"
        printf '%s\n' "[managed-deploy-agent] Detected public IP for runner_url: ${detected_public_ipv4} (cloud metadata)." >&2
    fi
fi
if [ -z "${detected_public_ipv4}" ]; then
    candidate="$(curl -4fsS --connect-timeout 1 --max-time 2 \
        -H "Metadata-Flavor: Google" \
        "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null || true)"
    candidate="$(printf '%s' "${candidate}" | tr -d '[:space:]')"
    if [ -n "${candidate}" ] && releasepanel_is_routable_agent_ipv4 "${candidate}"; then
        detected_public_ipv4="${candidate}"
        printf '%s\n' "[managed-deploy-agent] Detected public IP for runner_url: ${detected_public_ipv4} (GCP metadata)." >&2
    fi
fi
if [ -z "${detected_public_ipv4}" ]; then
    candidate="$(curl -4fsS --connect-timeout 1 --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    candidate="$(printf '%s' "${candidate}" | tr -d '[:space:]')"
    if [ -n "${candidate}" ] && releasepanel_is_routable_agent_ipv4 "${candidate}"; then
        detected_public_ipv4="${candidate}"
        printf '%s\n' "[managed-deploy-agent] Detected public IP for runner_url: ${detected_public_ipv4} (EC2-compatible metadata)." >&2
    fi
fi

if [ -z "${detected_public_ipv4}" ]; then
    printf '%s\n' "[managed-deploy-agent] Unable to determine a routable public IPv4 for runner_url (set MANAGED_AGENT_RUNNER_PUBLIC_URL or configure outbound HTTPS to ipify/ifconfig.me)." >&2
fi

# JSON public_ip field: same detection (unknown if we could not learn egress — panel may still accept registration without runner_url).
public_ip="${detected_public_ipv4}"

runner_port="${MANAGED_AGENT_RUNNER_PORT:-${RELEASEPANEL_RUNNER_PORT:-9000}}"

runner_url=""
if [ -n "${3:-}" ]; then
    runner_url="${3}"
elif [ -n "${MANAGED_AGENT_RUNNER_PUBLIC_URL:-}" ]; then
    runner_url="${MANAGED_AGENT_RUNNER_PUBLIC_URL}"
elif [ -n "${RELEASEPANEL_RUNNER_PUBLIC_URL:-}" ]; then
    runner_url="${RELEASEPANEL_RUNNER_PUBLIC_URL}"
else
    if [ -n "${detected_public_ipv4}" ]; then
        runner_url="http://${detected_public_ipv4}:${runner_port}"
        printf '%s\n' "[managed-deploy-agent] Using agent-derived runner_url=${runner_url} (override with MANAGED_AGENT_RUNNER_PUBLIC_URL for tunnel/Tailscale)." >&2
        if [ -z "${MANAGED_AGENT_RUNNER_HOST:-}" ] && [ -z "${RELEASEPANEL_RUNNER_HOST:-}" ]; then
            export MANAGED_AGENT_RUNNER_HOST=0.0.0.0
            export RELEASEPANEL_RUNNER_HOST=0.0.0.0
            printf '%s\n' "[managed-deploy-agent] Using MANAGED_AGENT_RUNNER_HOST=0.0.0.0 so the panel can reach ${runner_url} (restrict port ${runner_port} in your firewall)." >&2
        fi
    else
        runner_url=""
    fi
fi

runner_key="${MANAGED_AGENT_RUNNER_KEY:-${RELEASEPANEL_RUNNER_KEY:-}}"
server_id="${MANAGED_AGENT_SERVER_ID:-${RELEASEPANEL_SERVER_ID:-}}"

send_loopback_runner_in_json=false
case "${MANAGED_AGENT_REGISTER_SEND_LOOPBACK_RUNNER_URL:-${RELEASEPANEL_REGISTER_SEND_LOOPBACK_RUNNER_URL:-}}" in
    1 | true | TRUE | yes | YES | on | ON)
        send_loopback_runner_in_json=true
        ;;
esac

is_loopback_runner_url=false
case "${runner_url}" in
    http://127.0.0.1* | http://localhost* | https://127.0.0.1* | https://localhost*)
        is_loopback_runner_url=true
        ;;
    http://\[::1\]*:* | https://\[::1\]*:* | http://[::1]*:* | https://[::1]*:*)
        is_loopback_runner_url=true
        ;;
esac

omit_runner_url_from_json=false
if [ "${send_loopback_runner_in_json}" != true ]; then
    if [ -z "${runner_url}" ]; then
        omit_runner_url_from_json=true
        printf '%s\n' "[managed-deploy-agent] Omitting runner_url from registration JSON (no routable agent IPv4 / no MANAGED_AGENT_RUNNER_PUBLIC_URL)." >&2
    elif [ "${hosted_panel_expects_routable_runner_url}" = true ] && [ "${is_loopback_runner_url}" = true ]; then
        omit_runner_url_from_json=true
        printf '%s\n' "[managed-deploy-agent] Omitting runner_url from registration JSON (hosted panel + loopback MANAGED_AGENT_RUNNER_PUBLIC_URL)." >&2
    fi
fi

runner_public_url_for_env="${runner_url}"
if [ "${runner_explicit}" != true ]; then
    if [ -n "${detected_public_ipv4}" ]; then
        runner_public_url_for_env="http://${detected_public_ipv4}:${runner_port}"
    elif [ -z "${runner_url}" ]; then
        runner_public_url_for_env=""
    fi
else
    if [ "${is_loopback_runner_url}" = true ] && [ -n "${detected_public_ipv4}" ]; then
        runner_public_url_for_env="http://${detected_public_ipv4}:${runner_port}"
    fi
fi

if [ -z "${runner_key}" ] && [ -f "${RUNNER_ENV}" ]; then
    runner_key="$(grep -E '^MANAGED_AGENT_RUNNER_KEY=.' "${RUNNER_ENV}" | tail -n 1 | cut -d= -f2- || true)"
fi
if [ -z "${runner_key}" ] && [ -f "${RUNNER_ENV}" ]; then
    runner_key="$(grep -E '^RELEASEPANEL_RUNNER_KEY=.' "${RUNNER_ENV}" | tail -n 1 | cut -d= -f2- || true)"
fi

if [ -z "${runner_key}" ] || [ "${runner_key}" = "CHANGE_ME" ]; then
    runner_key="$(openssl rand -hex 32)"
fi

if [ -z "${MANAGED_AGENT_REGISTER_INSECURE_TLS:-}" ] && [ -z "${RELEASEPANEL_REGISTER_INSECURE_TLS:-}" ]; then
    case "${MANAGED_AGENT_DISABLE_AUTO_INSECURE_TLS:-${RELEASEPANEL_DISABLE_AUTO_INSECURE_TLS:-}}" in
        1 | true | TRUE | yes | YES | on | ON)
            ;;
        *)
            case "${panel_url_lc}" in
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

panel_install_key="${MANAGED_AGENT_ACCOUNT_KEY:-${RELEASEPANEL_AGENT_ACCOUNT_KEY:-${MANAGED_AGENT_PANEL_INSTALL_KEY:-${RELEASEPANEL_INSTALL_KEY:-${RELEASEPANEL_PANEL_INSTALL_KEY:-}}}}}}"
panel_install_key="${panel_install_key//$'\r'/}"
if [ -n "${panel_install_key}" ] && command -v python3 >/dev/null 2>&1; then
    panel_install_key="$(python3 -c 'import sys; print(sys.argv[1].strip())' "${panel_install_key}")"
fi

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

# reg_complete 0 = staging .env so a running agent can heartbeat during join + register completes.
write_runner_env() {
    local rk="$1"
    local reg_complete="$2"
    local tmp
    tmp="$(mktemp)"
    chmod 600 "${tmp}" 2>/dev/null || true
    {
        printf 'MANAGED_AGENT_RUNNER_HOST=%s\n' "${MANAGED_AGENT_RUNNER_HOST:-${RELEASEPANEL_RUNNER_HOST:-127.0.0.1}}"
        printf 'RELEASEPANEL_RUNNER_HOST=%s\n' "${RELEASEPANEL_RUNNER_HOST:-${MANAGED_AGENT_RUNNER_HOST:-127.0.0.1}}"
        printf 'MANAGED_AGENT_RUNNER_PORT=%s\n' "${runner_port}"
        printf 'RELEASEPANEL_RUNNER_PORT=%s\n' "${runner_port}"
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
        printf 'MANAGED_AGENT_RUNNER_PUBLIC_URL=%s\n' "${runner_public_url_for_env}"
        printf 'RELEASEPANEL_RUNNER_PUBLIC_URL=%s\n' "${runner_public_url_for_env}"
        if [ -n "${detected_public_ipv4:-}" ]; then
            printf 'MANAGED_AGENT_RUNNER_PUBLIC_IP=%s\n' "${detected_public_ipv4}"
            printf 'RELEASEPANEL_RUNNER_PUBLIC_IP=%s\n' "${detected_public_ipv4}"
        fi
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

if [ "${omit_runner_url_from_json}" = true ]; then
    payload="$(printf '{"name":%s,"hostname":%s,"public_ip":%s,"server_id":%s}' \
        "$(quote_json "${server_name}")" \
        "$(quote_json "${reported_hostname}")" \
        "$(quote_json "${public_ip:-unknown}")" \
        "$(quote_json "${server_id}")")"
else
    payload="$(printf '{"name":%s,"hostname":%s,"public_ip":%s,"runner_url":%s,"server_id":%s}' \
        "$(quote_json "${server_name}")" \
        "$(quote_json "${reported_hostname}")" \
        "$(quote_json "${public_ip:-unknown}")" \
        "$(quote_json "${runner_url}")" \
        "$(quote_json "${server_id}")")"
fi

if [ "${is_loopback_runner_url}" = true ] && [ "${omit_runner_url_from_json}" != true ]; then
    printf '%s\n' "[managed-deploy-agent] WARN: runner_url is ${runner_url}. The hosted panel cannot open that address from its own network. Set MANAGED_AGENT_RUNNER_PUBLIC_URL (tunnel, VPN URL, or http(s)://YOUR_PUBLIC_IP:9000 with bind 0.0.0.0 + firewall allowlist) then restart the agent. See docs/agent-panel-connection.md." >&2
fi

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
