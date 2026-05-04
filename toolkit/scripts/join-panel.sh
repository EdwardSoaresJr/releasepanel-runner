#!/usr/bin/env bash
# Explicit "join control plane" entrypoint for remote VPS (calls register-server.sh after a reachability probe).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    printf '[join-panel] error: %s\n' "$*" >&2
    exit 1
}

panel_url=""
positional=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --panel-url=*)
            panel_url="${1#*=}"
            shift
            ;;
        --account-key=* | --install-key=*)
            k="${1#*=}"
            export MANAGED_AGENT_ACCOUNT_KEY="${k}"
            export RELEASEPANEL_AGENT_ACCOUNT_KEY="${k}"
            export MANAGED_AGENT_PANEL_INSTALL_KEY="${k}"
            export RELEASEPANEL_INSTALL_KEY="${k}"
            shift
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            if [ -n "${positional}" ]; then
                fail "Unexpected argument: $1"
            fi
            positional="$1"
            shift
            ;;
    esac
done

if [ -z "${panel_url}" ]; then
    panel_url="${positional}"
fi

panel_url="${panel_url:-${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}}"
[ -n "${panel_url}" ] || fail "Usage: managed-deploy join https://panel.example.com   (or MANAGED_AGENT_PANEL_URL / --panel-url=)"

base="${panel_url%/}"
check_url="${base}/api/runner-connectivity-check"

echo "[join-panel] Probing panel API (no secrets): ${check_url}"

http_code=""
http_code_k=""

set +e
http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 "${check_url}" 2>/dev/null)"
curl_exit=$?
set -e

if [ "${http_code}" = "200" ] && [ "${curl_exit}" -eq 0 ]; then
    echo "[join-panel] OK — HTTPS reachable and certificate verified."
else
    set +e
    http_code_k="$(curl -sSk -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 "${check_url}" 2>/dev/null)"
    curl_exit_k=$?
    set -e
    if [ "${http_code_k}" != "200" ] || [ "${curl_exit_k}" -ne 0 ]; then
        fail "Cannot reach ${check_url} (curl exit ${curl_exit}, HTTP ${http_code}; insecure probe HTTP ${http_code_k}). Fix DNS, HTTPS, or outbound firewall; try: curl -v ${check_url}"
    fi

    # Only treat as "use curl -k / disable TLS verify" when curl explicitly failed *certificate verification*.
    # During panel/nginx reloads the verify probe often fails with exit 7 (connection) while -k still reaches HTTP 200 —
    # that must NOT flip MANAGED_AGENT_PANEL_INSECURE_TLS on a legitimate public CA deployment.
    ssl_verify_failed=false
    if [ "${curl_exit}" -eq 60 ] || [ "${curl_exit}" -eq 51 ]; then
        ssl_verify_failed=true
    fi

    case "${MANAGED_AGENT_DISABLE_AUTO_INSECURE_TLS:-${RELEASEPANEL_DISABLE_AUTO_INSECURE_TLS:-}}" in
        1 | true | TRUE | yes | YES | on | ON)
            printf '%s\n' "[join-panel] WARN: verified TLS probe failed (curl exit ${curl_exit}) but -k reached HTTP 200. MANAGED_AGENT_DISABLE_AUTO_INSECURE_TLS is set — export MANAGED_AGENT_REGISTER_INSECURE_TLS=1 / MANAGED_AGENT_PANEL_INSECURE_TLS=1 manually if this panel uses a private CA." >&2
            ;;
        *)
            if [ "${ssl_verify_failed}" = true ]; then
                echo "[join-panel] WARN — HTTPS certificate verification failed (curl exit ${curl_exit}); panel reachable with verify disabled (typical private CA / untrusted panel cert)." >&2
                export MANAGED_AGENT_REGISTER_INSECURE_TLS=1
                export RELEASEPANEL_REGISTER_INSECURE_TLS=1
                export MANAGED_AGENT_PANEL_INSECURE_TLS=1
                export RELEASEPANEL_PANEL_INSECURE_TLS=1
                echo "[join-panel] Exported MANAGED_AGENT_REGISTER_INSECURE_TLS=1 and MANAGED_AGENT_PANEL_INSECURE_TLS=1 for registration + agent heartbeats." >&2
            else
                printf '%s\n' "[join-panel] WARN: verified TLS probe failed (curl exit ${curl_exit}, HTTP ${http_code}) but -k succeeded — likely deploy/nginx restart or network flake; not auto-enabling insecure TLS (only curl exits 60/51 do)." >&2
            fi
            ;;
    esac
fi

case "${MANAGED_AGENT_TAILSCALE_BIND:-}" in
    1 | true | TRUE | yes | YES | on | ON)
        if [ -z "${MANAGED_AGENT_RUNNER_HOST:-}" ] && [ -z "${RELEASEPANEL_RUNNER_HOST:-}" ]; then
            export MANAGED_AGENT_RUNNER_HOST=0.0.0.0
        fi
        echo "[join-panel] MANAGED_AGENT_TAILSCALE_BIND=1 — MANAGED_AGENT_RUNNER_HOST=${MANAGED_AGENT_RUNNER_HOST:-${RELEASEPANEL_RUNNER_HOST:-127.0.0.1}} (restrict tcp/9000 to Tailscale 100.64.0.0/10; see docs/agent-panel-connection.md)." >&2
        ;;
esac

install_key_effective="${MANAGED_AGENT_ACCOUNT_KEY:-${RELEASEPANEL_AGENT_ACCOUNT_KEY:-${MANAGED_AGENT_PANEL_INSTALL_KEY:-${RELEASEPANEL_INSTALL_KEY:-}}}}"
if [ -n "${install_key_effective}" ]; then
    echo "[join-panel] Account install key: present (--account-key= / MANAGED_AGENT_ACCOUNT_KEY)."
else
    printf '%s\n' "[join-panel] WARN: no account install key in environment. If registration fails with account_install_key_required, pass --account-key= or export MANAGED_AGENT_ACCOUNT_KEY." >&2
fi

echo "[join-panel] Running registration (writes agent .env + POST /api/register-runner)..."
exec bash "${SCRIPT_DIR}/register-server.sh" "${panel_url}"
