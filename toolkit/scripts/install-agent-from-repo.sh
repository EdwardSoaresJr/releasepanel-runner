#!/usr/bin/env bash
# Full managed-deploy-agent install: Node, deps, systemd, registration, service start.
# Invoked from the cloned releasepanel-runner tree by scripts/install.sh (panel or raw).
# Expects: root, INSTALL_ROOT already populated with the repo, MANAGED_AGENT_PANEL_URL / PANEL_URL set upstream.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLKIT="${INSTALL_ROOT}/toolkit"

PANEL_URL="${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-${PANEL_URL:-}}}"
RUNNER_KEY="${MANAGED_AGENT_RUNNER_KEY:-${RELEASEPANEL_RUNNER_KEY:-}}"
INSTALL_KEY="${MANAGED_AGENT_ACCOUNT_KEY:-${RELEASEPANEL_AGENT_ACCOUNT_KEY:-${MANAGED_AGENT_PANEL_INSTALL_KEY:-${RELEASEPANEL_INSTALL_KEY:-}}}}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i or ssh root@…)."
}

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        PM=apt
        return 0
    fi
    if command -v dnf >/dev/null 2>&1; then
        PM=dnf
        return 0
    fi
    die "No supported package manager (need apt-get or dnf). Use Ubuntu/Debian or RHEL-compatible."
}

install_base_packages() {
    case "${PM}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            APT_OPT="${INSTALL_ROOT}/scripts/lib/apt-optimizations.sh"
            if [ -r "${APT_OPT}" ]; then
                # shellcheck source=/dev/null
                . "${APT_OPT}"
            fi
            if command -v force_ipv4_apt >/dev/null 2>&1; then
                force_ipv4_apt || true
                force_fast_apt_mirrors || true
                clean_apt_cache_safe || true
            fi
            apt-get update -y
            apt-get install -y curl ca-certificates git python3
            ;;
        dnf)
            dnf install -y curl ca-certificates git python3
            ;;
        *)
            die "internal: bad PM"
            ;;
    esac
}

install_node20_apt() {
    if command -v node >/dev/null 2>&1 && node --version | grep -qE '^v(2[0-9]|[3-9][0-9])\.'; then
        return 0
    fi
    case "${PM}" in
        apt)
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt-get install -y nodejs
            ;;
        dnf)
            dnf install -y nodejs npm || dnf install -y nodejs
            ;;
    esac
    command -v node >/dev/null 2>&1 || die "node failed to install (need Node 20+)."
    command -v npm >/dev/null 2>&1 || die "npm missing after node install."
}

verify_node_major() {
    local major
    major="$(node -p "parseInt(process.versions.node, 10) || 0" 2>/dev/null || echo 0)"
    if [ "${major}" -lt 20 ]; then
        die "Node 20+ is required (found $(node -v 2>/dev/null || echo 'none'))."
    fi
}

agent_env_registration_complete() {
    local f="${INSTALL_ROOT}/.env"
    [ -f "${f}" ] || return 1
    if grep -qE '^MANAGED_AGENT_RUNNER_KEY=CHANGE_ME$' "${f}" 2>/dev/null; then
        return 1
    fi
    if ! grep -qE '^MANAGED_AGENT_RUNNER_KEY=[^[:space:]]+' "${f}" 2>/dev/null; then
        return 1
    fi
    grep -qE '^MANAGED_AGENT_REGISTRATION_COMPLETE=1([[:space:]]|$)' "${f}" 2>/dev/null
}

panel_url_from_agent_env() {
    local f="${INSTALL_ROOT}/.env"
    [ -f "${f}" ] || return 0
    grep -E '^MANAGED_AGENT_PANEL_URL=' "${f}" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r' || true
}

effective_runner_public_url() {
    local f="${INSTALL_ROOT}/.env"
    local v=""
    if [ -f "${f}" ]; then
        v="$(grep -E '^MANAGED_AGENT_RUNNER_PUBLIC_URL=' "${f}" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r')"
        if [ -z "${v}" ]; then
            v="$(grep -E '^RELEASEPANEL_RUNNER_PUBLIC_URL=' "${f}" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r')"
        fi
    fi
    if [ -n "${v}" ]; then
        printf '%s' "${v}"
    else
        printf '%s' "http://127.0.0.1:9000"
    fi
}

secure_install_root_permissions() {
    chmod 700 "${INSTALL_ROOT}" || true
    if [ -f "${INSTALL_ROOT}/.env" ]; then
        chmod 600 "${INSTALL_ROOT}/.env" || true
    fi
}

trust_install_root_git() {
    [ -d "${INSTALL_ROOT}/.git" ] || return 0
    git config --global --add safe.directory "${INSTALL_ROOT}" 2>/dev/null || true
}

validate_panel_url() {
    local u="$1"
    case "${u}" in
        http://* | https://*) ;;
        *) die "Panel URL must start with http:// or https:// (got: ${u:-empty})" ;;
    esac
}

prompt_panel_url_if_needed() {
    if [ -n "${PANEL_URL}" ]; then
        [ "${NON_INTERACTIVE}" -eq 1 ] || return 0
        return 0
    fi
    if [ "${NON_INTERACTIVE}" -eq 1 ]; then
        die "Missing --panel-url= or MANAGED_AGENT_PANEL_URL (non-interactive)."
    fi
    printf '%s' "ReleasePanel URL (https://…): " >&2
    read -r PANEL_URL
    [ -n "${PANEL_URL}" ] || die "Panel URL required."
}

connectivity_hint() {
    local base="${PANEL_URL%/}"
    local check_url="${base}/api/runner-connectivity-check"
    set +e
    curl -fsS --connect-timeout 15 --max-time 30 "${check_url}" >/dev/null 2>&1
    local ev=$?
    set -e
    if [ "${ev}" -ne 0 ]; then
        warn "Optional connectivity check failed (${check_url}). Agent may still be fine once registered."
        warn "Check: DNS, HTTPS outbound, firewall, and that the panel URL is correct."
    else
        log "Panel API reachable (${check_url})."
    fi
}

ensure_default_agent_poll_env() {
    local f="$1"
    [ -f "${f}" ] || return 0
    if grep -qE '^MANAGED_AGENT_POLL_ENABLED=' "${f}" || grep -qE '^RELEASEPANEL_POLL_ENABLED=' "${f}"; then
        return 0
    fi
    {
        printf '\n# Outbound job poll (on by default — panel delivers Prepare / deploy / site / SSL work here)\n'
        printf 'MANAGED_AGENT_POLL_ENABLED=true\n'
        printf 'RELEASEPANEL_POLL_ENABLED=true\n'
    } >> "${f}"
    chmod 600 "${f}"
}

main() {
    require_root
    log "Using install root (repo): ${INSTALL_ROOT}"
    [ -f "${INSTALL_ROOT}/server.js" ] || die "${INSTALL_ROOT}/server.js missing — clone or sync releasepanel-runner first."
    [ -f "${TOOLKIT}/scripts/join-panel.sh" ] || die "Missing ${TOOLKIT}/scripts/join-panel.sh"

    detect_pm
    install_base_packages
    install_node20_apt
    verify_node_major
    secure_install_root_permissions
    trust_install_root_git

    SKIP_JOIN=0
    if agent_env_registration_complete; then
        SKIP_JOIN=1
        log "Agent .env shows a completed registration; skipping join-panel."
        if [ -z "${PANEL_URL}" ]; then
            PANEL_URL="$(panel_url_from_agent_env)"
        fi
    else
        prompt_panel_url_if_needed
    fi

    PANEL_URL="${PANEL_URL%/}"
    [ -n "${PANEL_URL}" ] || die "Panel URL required (--panel-url= or MANAGED_AGENT_PANEL_URL)."
    validate_panel_url "${PANEL_URL}"

    export RELEASEPANEL_TOOLKIT_DIR="${TOOLKIT}"
    export MANAGED_AGENT_PANEL_URL="${PANEL_URL}"
    export RELEASEPANEL_PANEL_URL="${PANEL_URL}"
    if [ -n "${INSTALL_KEY}" ]; then
        export MANAGED_AGENT_ACCOUNT_KEY="${INSTALL_KEY}"
        export RELEASEPANEL_AGENT_ACCOUNT_KEY="${INSTALL_KEY}"
        export MANAGED_AGENT_PANEL_INSTALL_KEY="${INSTALL_KEY}"
        export RELEASEPANEL_INSTALL_KEY="${INSTALL_KEY}"
    fi
    if [ "${SKIP_JOIN}" -eq 0 ]; then
        # Initial onboarding: leave runner key empty so register-server.sh generates one. Do not pass
        # MANAGED_AGENT_RUNNER_KEY / --runner-key from the panel one-liner.
        export MANAGED_AGENT_RUNNER_KEY="${RUNNER_KEY}"
        export RELEASEPANEL_RUNNER_KEY="${RUNNER_KEY}"
    fi

    # shellcheck source=/dev/null
    . "${TOOLKIT}/lib/common.sh"

    log "Installing Node dependencies (${INSTALL_ROOT})…"
    releasepanel_managed_agent_install_node_modules "${INSTALL_ROOT}" || die "npm install failed."

    secure_install_root_permissions

    if command -v systemctl >/dev/null 2>&1; then
        NODE_BIN_FOR_UNIT="$(command -v node 2>/dev/null || true)"
        [ -n "${NODE_BIN_FOR_UNIT}" ] || die "node not found on PATH (cannot write systemd unit)."
        [ -x "${NODE_BIN_FOR_UNIT}" ] || die "node binary not executable at ${NODE_BIN_FOR_UNIT}"
        log "Using Node at: ${NODE_BIN_FOR_UNIT} (systemd ExecStart)"
        log "Writing systemd unit…"
        releasepanel_write_managed_agent_systemd_unit "${INSTALL_ROOT}" "${TOOLKIT}" "${NODE_BIN_FOR_UNIT}" || die "systemd unit failed."
    else
        warn "systemd not found — skipping systemd unit and service. You will start the agent manually after registration."
    fi

    if [ -x "${TOOLKIT}/bin/managed-deploy" ]; then
        ln -sf "${TOOLKIT}/bin/managed-deploy" /usr/local/bin/managed-deploy 2>/dev/null || true
    fi

    if [ "${SKIP_JOIN}" -eq 0 ]; then
        log "Registering server with panel…"
        bash "${TOOLKIT}/scripts/join-panel.sh" "${PANEL_URL}"
        secure_install_root_permissions
    fi

    ensure_default_agent_poll_env "${INSTALL_ROOT}/.env"

    if [ -f "${INSTALL_ROOT}/.env" ]; then
        log "Runner URL: $(effective_runner_public_url)"
    else
        warn "Runner URL: (not configured yet — no ${INSTALL_ROOT}/.env)"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        mkdir -p "${INSTALL_ROOT}"
        printf '\n' >&2
        printf '  Foreground:\n' >&2
        printf '    cd %q\n' "${INSTALL_ROOT}" >&2
        printf '    exec node server.js\n' >&2
        printf '  Background:\n' >&2
        printf '    cd %q\n' "${INSTALL_ROOT}" >&2
        printf '    nohup node server.js > managed-deploy-agent.log 2>&1 &\n' >&2
        printf '    disown\n' >&2
        printf '\n' >&2
        log "Runtime: Node $(node -v), npm $(npm -v)"
        connectivity_hint

        printf '\n'
        warn "Firewall: allow outbound HTTPS to your panel; agent poll mode needs no inbound ports by default."
        printf '\n'
        log "Done (no systemd)."
        printf '  • ReleasePanel Agent version: %s\n' "$(git -C "${INSTALL_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        printf '  • Log file: %s/managed-deploy-agent.log\n' "${INSTALL_ROOT}"
        printf '  • Logs: terminal where you run node (no journalctl without systemd)\n'
        printf '  • Next: open ReleasePanel → verify server online → Prepare server → Create site → Deploy\n'
        printf '\n'
        exit 0
    fi

    log "Starting agent service…"
    systemctl daemon-reload
    systemctl enable managed-deploy-agent
    if ! systemctl restart managed-deploy-agent; then
        warn "systemctl restart failed; retrying in 2s…"
        sleep 2
        systemctl restart managed-deploy-agent || {
            printf '\n' >&2
            die "managed-deploy-agent failed to restart. Diagnostics: journalctl -u managed-deploy-agent -n 50 --no-pager"
        }
    fi

    log "Agent service is active."
    log "Runtime: Node $(node -v), npm $(npm -v)"
    connectivity_hint

    printf '\n'
    warn "Firewall: allow outbound HTTPS to your panel; agent poll mode needs no inbound ports by default."
    printf '\n'
    log "Done."
    printf '  • ReleasePanel Agent version: %s\n' "$(git -C "${INSTALL_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf '  • Service: %s\n' "$(systemctl is-active managed-deploy-agent 2>/dev/null || echo unknown)"
    printf '  • managed-deploy-agent: systemctl status managed-deploy-agent\n'
    printf '  • Follow logs: journalctl -u managed-deploy-agent -f\n'
    printf '  • Next: open ReleasePanel → verify server online → Prepare server → Create site → Deploy\n'
    printf '\n'
}

main "$@"
