#!/usr/bin/env bash
# ReleasePanel one-liner bootstrap: install managed-deploy-agent only (no nginx/php/prepare/site).
# Usage (strict HTTPS fetch — public raw URL from releasepanel-runner by default):
#   curl -fsSL --proto '=https' --tlsv1.2 'https://raw.githubusercontent.com/EdwardSoaresJr/releasepanel-runner/main/scripts/install.sh' | sudo bash -s -- \
#     --non-interactive --panel-url='https://YOUR_PANEL' --runner-key='SECRET'
# Env (alternative to flags): MANAGED_AGENT_PANEL_URL, MANAGED_AGENT_RUNNER_KEY
set -Eeuo pipefail

readonly INSTALL_ROOT="${MANAGED_AGENT_INSTALL_ROOT:-/opt/managed-deploy-agent}"
readonly DEFAULT_REPO="${MANAGED_AGENT_REPO_URL:-${RELEASEPANEL_RUNNER_REPO_HTTPS:-https://github.com/EdwardSoaresJr/releasepanel-runner.git}}"
readonly DEFAULT_BRANCH="${MANAGED_AGENT_REPO_BRANCH:-${RELEASEPANEL_RUNNER_BRANCH:-main}}"

PANEL_URL="${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}"
RUNNER_KEY="${MANAGED_AGENT_RUNNER_KEY:-${RELEASEPANEL_RUNNER_KEY:-}}"
INSTALL_AGENT=1
NON_INTERACTIVE=0

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
ReleasePanel agent bootstrap (thin): installs managed-deploy-agent only — no nginx/php/prepare.

Usage:
  curl -fsSL --proto '=https' --tlsv1.2 'https://example.com/install.sh' | sudo bash -s -- --panel-url='https://panel.example.com' --runner-key=SECRET

Options:
  --panel-url=URL       Control plane base URL
  --runner-key=SECRET   Server runner key (prefer MANAGED_AGENT_RUNNER_KEY env over argv)
  --non-interactive     Fail if URL or key missing
  --ssh-only            Skip agent; print SSH-only hints
  --agent               Install agent (default)
  --help                This help

Env: MANAGED_AGENT_PANEL_URL, MANAGED_AGENT_RUNNER_KEY, MANAGED_AGENT_INSTALL_ROOT, MANAGED_AGENT_REPO_URL
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --panel-url=*)
                PANEL_URL="${1#*=}"
                shift
                ;;
            --runner-key=*)
                RUNNER_KEY="${1#*=}"
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --ssh-only)
                INSTALL_AGENT=0
                shift
                ;;
            --agent)
                INSTALL_AGENT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1 (use --help)"
                ;;
        esac
    done
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i or ssh root@…)."
}

acquire_install_lock() {
    local lock_file=/var/lock/releasepanel-install.lock
    local lock_dir
    lock_dir="$(dirname "${lock_file}")"
    install -d -m 0755 "${lock_dir}" 2>/dev/null || true
    if ! command -v flock >/dev/null 2>&1; then
        warn "flock not found; concurrent install guard skipped (install util-linux where needed)."
        return 0
    fi
    exec 9>"${lock_file}" || die "Cannot open lock file ${lock_file}"
    if ! flock -n 9; then
        die "Another install is already running (lock: ${lock_file})."
    fi
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

agent_env_has_runner_key() {
    local f="${INSTALL_ROOT}/.env"
    [ -f "${f}" ] || return 1
    grep -qE '^MANAGED_AGENT_RUNNER_KEY=.' "${f}" 2>/dev/null || return 1
    if grep -qE '^MANAGED_AGENT_RUNNER_KEY=CHANGE_ME$' "${f}" 2>/dev/null; then
        return 1
    fi
    return 0
}

panel_url_from_agent_env() {
    local f="${INSTALL_ROOT}/.env"
    [ -f "${f}" ] || return 0
    grep -E '^MANAGED_AGENT_PANEL_URL=' "${f}" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r' || true
}

# URL the panel should use for runner HTTP (from .env after join); defaults to loopback.
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

install_or_refresh_clone() {
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

    if [ -d "${INSTALL_ROOT}/.git" ]; then
        log "Existing clone at ${INSTALL_ROOT}; updating ${DEFAULT_BRANCH}…"
        if ! git -C "${INSTALL_ROOT}" fetch --depth 1 origin "${DEFAULT_BRANCH}" 2>/dev/null; then
            warn "Git fetch failed, recloning…"
            rm -rf "${INSTALL_ROOT}"
        else
            git -C "${INSTALL_ROOT}" checkout "${DEFAULT_BRANCH}" 2>/dev/null || true
            git -C "${INSTALL_ROOT}" pull --ff-only origin "${DEFAULT_BRANCH}" 2>/dev/null || warn "git pull failed; using on-disk tree."
            secure_install_root_permissions
            return 0
        fi
    fi

    if [ -e "${INSTALL_ROOT}" ]; then
        die "${INSTALL_ROOT} exists and is not a git clone. Remove it or set MANAGED_AGENT_INSTALL_ROOT."
    fi

    log "Cloning agent bundle (${DEFAULT_BRANCH}) → ${INSTALL_ROOT}…"
    install -d -m 0755 "$(dirname "${INSTALL_ROOT}")"
    git clone --depth 1 --branch "${DEFAULT_BRANCH}" "${DEFAULT_REPO}" "${INSTALL_ROOT}"
    secure_install_root_permissions
}

validate_panel_url() {
    local u="$1"
    case "${u}" in
        http://* | https://*) ;;
        *) die "Panel URL must start with http:// or https:// (got: ${u:-empty})" ;;
    esac
}

prompt_missing() {
    if [ -n "${PANEL_URL}" ] && [ -n "${RUNNER_KEY}" ]; then
        return 0
    fi
    if [ "${NON_INTERACTIVE}" -eq 1 ]; then
        [ -n "${PANEL_URL}" ] || die "Missing --panel-url= or MANAGED_AGENT_PANEL_URL (non-interactive)."
        [ -n "${RUNNER_KEY}" ] || die "Missing --runner-key= or MANAGED_AGENT_RUNNER_KEY (non-interactive)."
        return 0
    fi
    if [ -z "${PANEL_URL}" ]; then
        printf '%s' "ReleasePanel URL (https://…): " >&2
        read -r PANEL_URL
    fi
    if [ -z "${RUNNER_KEY}" ]; then
        printf '%s' "Runner key (from ReleasePanel server; input hidden): " >&2
        read -rs RUNNER_KEY
        printf '\n' >&2
    fi
    [ -n "${PANEL_URL}" ] || die "Panel URL required."
    [ -n "${RUNNER_KEY}" ] || die "Runner key required."
    [ "${RUNNER_KEY}" != "CHANGE_ME" ] || die "Runner key must not be CHANGE_ME."
}

ssh_only_message() {
    log "SSH-only mode — no agent will be installed."
    printf '\nAdd this server in ReleasePanel using SSH (host, user, private key).\n'
    printf 'Use Prepare server / Create site / Deploy from the panel when ready.\n\n'
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
    parse_args "$@"

    if [ "${INSTALL_AGENT}" -eq 0 ]; then
        require_root
        ssh_only_message
        exit 0
    fi

    require_root
    acquire_install_lock
    log "Using install root: ${INSTALL_ROOT}"
    detect_pm
    install_base_packages
    install_node20_apt
    verify_node_major
    install_or_refresh_clone
    secure_install_root_permissions
    trust_install_root_git

    [ -f "${INSTALL_ROOT}/server.js" ] || die "${INSTALL_ROOT}/server.js missing after clone."
    TOOLKIT="${INSTALL_ROOT}/toolkit"
    [ -f "${TOOLKIT}/scripts/join-panel.sh" ] || die "toolkit missing ${TOOLKIT}/scripts/join-panel.sh — use a releasepanel-runner commit that vendors toolkit/ (join-panel ships in toolkit/scripts). Try: rm -rf ${INSTALL_ROOT} and re-run this installer, or: git -C ${INSTALL_ROOT} pull --ff-only origin ${DEFAULT_BRANCH}"

    SKIP_JOIN=0
    if agent_env_has_runner_key; then
        SKIP_JOIN=1
        log "Agent .env already has a runner key; skipping registration (join-panel)."
        if [ -z "${PANEL_URL}" ]; then
            PANEL_URL="$(panel_url_from_agent_env)"
        fi
    else
        prompt_missing
    fi

    PANEL_URL="${PANEL_URL%/}"
    [ -n "${PANEL_URL}" ] || die "Panel URL required (--panel-url= or MANAGED_AGENT_PANEL_URL)."
    validate_panel_url "${PANEL_URL}"

    export RELEASEPANEL_TOOLKIT_DIR="${TOOLKIT}"
    export MANAGED_AGENT_PANEL_URL="${PANEL_URL}"
    if [ "${SKIP_JOIN}" -eq 0 ]; then
        export MANAGED_AGENT_RUNNER_KEY="${RUNNER_KEY}"
        export RELEASEPANEL_PANEL_URL="${PANEL_URL}"
        export RELEASEPANEL_RUNNER_KEY="${RUNNER_KEY}"
    fi

    # shellcheck source=/dev/null
    . "${TOOLKIT}/lib/common.sh"

    # Node deps (toolkit): npm ci --omit=dev --no-audit --no-fund --prefer-offline || npm install --omit=dev --no-audit --no-fund — with retries + timeout; see releasepanel_managed_agent_install_node_modules.
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
        log "Registering with panel (writes ${INSTALL_ROOT}/.env)…"
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
