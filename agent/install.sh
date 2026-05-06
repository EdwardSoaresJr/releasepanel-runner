#!/usr/bin/env bash
# Standalone managed-deploy agent installer (served as GET /agent/install.sh).
# Intended for: curl -fsSL "$PANEL/agent/install.sh" | sudo bash -s -- --panel-url=... --join-token=...
# No BASH_SOURCE, no sourced ./lib helpers, no paths relative to stdin — only fixed install root + clone.
set -Eeuo pipefail

readonly INSTALL_ROOT="${MANAGED_AGENT_INSTALL_ROOT:-/opt/managed-deploy-agent}"
readonly DEFAULT_REPO="${MANAGED_AGENT_REPO_URL:-${RELEASEPANEL_RUNNER_REPO:-${RELEASEPANEL_RUNNER_REPO_HTTPS:-https://github.com/EdwardSoaresJr/releasepanel-runner.git}}}"
readonly DEFAULT_BRANCH="${MANAGED_AGENT_REPO_BRANCH:-${RELEASEPANEL_RUNNER_BRANCH:-main}}"

PANEL_URL="${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}"
JOIN_TOKEN="${MANAGED_AGENT_JOIN_TOKEN:-${RELEASEPANEL_JOIN_TOKEN:-}}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
INSTALL_AGENT=1

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
ReleasePanel agent installer (clone + Node + systemd + join).

Usage:
  curl -fsSL 'https://YOUR_PANEL/agent/install.sh' | sudo bash -s -- \\
    --panel-url='https://YOUR_PANEL' \\
    --join-token='TOKEN'

Options:
  --panel-url=URL     Control plane base URL
  --join-token=TOKEN  Single-use join token (X-JOIN-TOKEN on register-runner)
  --non-interactive   Fail if panel URL is missing when required
  --ssh-only          Skip agent; print SSH-only hints
  --agent             Install agent (default)
  --help

Override clone: MANAGED_AGENT_REPO_URL or RELEASEPANEL_RUNNER_REPO
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --panel-url=*)
                PANEL_URL="${1#*=}"
                shift
                ;;
            --join-token=*)
                JOIN_TOKEN="${1#*=}"
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
    install -d -m 0755 /var/lock 2>/dev/null || true
    if ! command -v flock >/dev/null 2>&1; then
        warn "flock not found; concurrent install guard skipped (install util-linux where needed)."
        return 0
    fi
    exec 9>"${lock_file}" || die "Cannot open lock file ${lock_file}"
    if ! flock -n 9; then
        die "Another install is already running (lock: ${lock_file})."
    fi
}

# Bootstrap before repo exists (mirrors scripts/install.sh — inlined, no extra sources).
_rp_git_bootstrap_apt_prepare() {
    if ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi
    echo "[apt] forcing IPv4"
    install -d -m 0755 /etc/apt/apt.conf.d || true
    cat >/etc/apt/apt.conf.d/99releasepanel-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF
    cat >/etc/apt/apt.conf.d/99releasepanel-apt-performance <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Queue-Mode "host";
APT::Install-Recommends "0";
APT::Install-Suggests "0";
DPkg::Use-Pty "0";
DPkg::Options { "--force-confdef"; "--force-confold"; };
EOF

    echo "[apt] detecting fast mirror" >&2
    local codename="noble"
    if grep -q '^VERSION_CODENAME=' /etc/os-release 2>/dev/null; then
        codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' | head -n1)"
    fi
    local do_base="http://mirrors.digitalocean.com/ubuntu"
    local ar_base="http://archive.ubuntu.com/ubuntu"
    local mirror_base="${ar_base}"
    local t=2
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS -m "${t}" --head -o /dev/null "${do_base}/dists/${codename}/InRelease" 2>/dev/null; then
            mirror_base="${do_base}"
        elif curl -fsS -m "${t}" --head -o /dev/null "${ar_base}/dists/${codename}/InRelease" 2>/dev/null; then
            mirror_base="${ar_base}"
        fi
    fi
    echo "[apt] selected mirror: ${mirror_base}" >&2

    if grep -qi ubuntu /etc/os-release 2>/dev/null; then
        if [ -f /etc/apt/sources.list ]; then
            sed -E -i \
                -e "s|https?://archive\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
                -e "s|https?://security\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
                -e "s|https?://[a-zA-Z0-9.-]+\\.clouds\\.archive\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
                /etc/apt/sources.list 2>/dev/null || true
        fi
        local f=""
        shopt -s nullglob 2>/dev/null || true
        for f in /etc/apt/sources.list.d/*.sources; do
            case "${f}" in
                *nodesource* | *Nodesource*) continue ;;
                *digitalocean* | *DigitalOcean* | *droplet*) continue ;;
            esac
            [ -f "${f}" ] || continue
            sed -E -i \
                -e "s|https?://archive\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
                -e "s|https?://security\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
                -e "s|https?://[a-zA-Z0-9.-]+\\.clouds\\.archive\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
                "${f}" 2>/dev/null || true
        done
        shopt -u nullglob 2>/dev/null || true
    fi
    echo "[apt] cleaning apt cache"
    rm -rf /var/lib/apt/lists/*
    apt-get clean 2>/dev/null || true
}

_rp_git_bootstrap_apt_update_safe() {
    if ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi
    local attempt
    attempt=1
    while [ "${attempt}" -le 3 ]; do
        echo "[apt] updating indexes"
        if apt-get update -y; then
            [ "${attempt}" -le 1 ] || echo "[apt] recovered after ${attempt} attempts"
            return 0
        fi
        if [ "${attempt}" -eq 3 ]; then
            echo "[apt] ERROR: apt update failed after 3 attempts" >&2
            return 1
        fi
        echo "[apt] update failed attempt ${attempt}/3"
        _rp_git_bootstrap_apt_prepare || true
        sleep 3
        attempt=$((attempt + 1))
    done
    return 1
}

ensure_git() {
    if command -v git >/dev/null 2>&1; then
        return 0
    fi
    log "Installing git…"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        _rp_git_bootstrap_apt_prepare || true
        _rp_git_bootstrap_apt_update_safe || die "apt-get update failed after mirror tuning"
        apt-get install -y --no-install-recommends git ca-certificates
        return 0
    fi
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y git ca-certificates
        return 0
    fi
    die "git is required but no supported package manager found."
}

validate_panel_url() {
    local u="$1"
    case "${u}" in
        http://* | https://*) ;;
        *) die "Panel URL must start with http:// or https:// (got: ${u:-empty})" ;;
    esac
}

secure_install_root_permissions() {
    chmod 700 "${INSTALL_ROOT}" 2>/dev/null || true
    if [ -f "${INSTALL_ROOT}/.env" ]; then
        chmod 600 "${INSTALL_ROOT}/.env" 2>/dev/null || true
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
        log "Updating agent repo at ${INSTALL_ROOT} (${DEFAULT_BRANCH}) — resetting to origin/${DEFAULT_BRANCH}…"
        if git -C "${INSTALL_ROOT}" remote get-url origin >/dev/null 2>&1; then
            git -C "${INSTALL_ROOT}" remote set-url origin "${DEFAULT_REPO}"
        else
            git -C "${INSTALL_ROOT}" remote add origin "${DEFAULT_REPO}"
        fi
        if ! git -C "${INSTALL_ROOT}" fetch --depth 1 origin "${DEFAULT_BRANCH}"; then
            die "git fetch failed (network/SSH?). Fix connectivity, then re-run."
        fi
        if ! git -C "${INSTALL_ROOT}" checkout -B "${DEFAULT_BRANCH}" "origin/${DEFAULT_BRANCH}"; then
            die "Could not sync to origin/${DEFAULT_BRANCH}."
        fi
        secure_install_root_permissions
        trust_install_root_git
        if [ ! -f "${INSTALL_ROOT}/server.js" ]; then
            die "Synced repo is missing server.js. Check repo URL / branch."
        fi
        return 0
    fi

    if [ -e "${INSTALL_ROOT}" ] && [ ! -d "${INSTALL_ROOT}/.git" ]; then
        die "${INSTALL_ROOT} exists and is not a git clone. Remove it or set MANAGED_AGENT_INSTALL_ROOT."
    fi

    log "Cloning agent repo (${DEFAULT_BRANCH}) → ${INSTALL_ROOT}…"
    install -d -m 0755 "$(dirname "${INSTALL_ROOT}")"
    git clone --depth 1 --branch "${DEFAULT_BRANCH}" "${DEFAULT_REPO}" "${INSTALL_ROOT}"
    secure_install_root_permissions
    trust_install_root_git
}

ssh_only_message() {
    log "SSH-only mode — no agent will be installed."
    printf '\nAdd this server in ReleasePanel using SSH (host, user, private key).\n'
    printf 'Use Prepare server / Create site / Deploy from the panel when ready.\n\n'
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
    die "No supported package manager (need apt-get or dnf)."
}

install_base_packages() {
    case "${PM}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            _rp_git_bootstrap_apt_prepare || true
            _rp_git_bootstrap_apt_update_safe || die "apt-get update failed after mirror tuning"
            apt-get install -y --no-install-recommends curl ca-certificates git python3
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

prompt_panel_url_if_needed() {
    if [ -n "${PANEL_URL}" ]; then
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
        printf '\n# Outbound job poll (on by default)\n'
        printf 'MANAGED_AGENT_POLL_ENABLED=true\n'
        printf 'RELEASEPANEL_POLL_ENABLED=true\n'
    } >> "${f}"
    chmod 600 "${f}"
}

agent_install_node_modules() {
    local runner_dir="$1"
    local npm_timeout="${RELEASEPANEL_NPM_TIMEOUT_SECONDS:-900}"

    _rp_agent_npm() {
        if command -v timeout >/dev/null 2>&1; then
            timeout "${npm_timeout}" "$@"
        else
            "$@"
        fi
    }

    trap 'unset -f _rp_agent_npm 2>/dev/null' RETURN

    if ! (
        cd "${runner_dir}" || exit 1
        if [ -f package-lock.json ]; then
            prefer_offline=(--prefer-offline)
            attempt=1
            while [ "${attempt}" -le 3 ]; do
                if _rp_agent_npm npm ci --omit=dev --no-audit --no-fund "${prefer_offline[@]}"; then
                    break
                fi
                if [ "${attempt}" -eq 3 ]; then
                    warn "npm ci failed after 3 attempts; falling back to npm install."
                    _rp_agent_npm npm install --omit=dev --no-audit --no-fund || exit 1
                    break
                fi
                warn "npm ci failed (attempt ${attempt}/3); retrying..."
                sleep $((attempt * 4))
                attempt=$((attempt + 1))
            done
        else
            _rp_agent_npm npm install --omit=dev --no-audit --no-fund || exit 1
        fi
    ); then
        die "npm install failed in ${runner_dir}"
    fi

    if ! ( cd "${runner_dir}" && node --check server.js ); then
        die "server.js syntax check failed (${runner_dir})"
    fi

    if ! (
        cd "${runner_dir}" || exit 1
        node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));for(const d of Object.keys(p.dependencies||{})){require(d);}"
    ); then
        die "Dependencies incomplete after npm install (${runner_dir})"
    fi
}

write_managed_agent_systemd_unit() {
    local runner_dir="$1"
    local toolkit_dir="$2"
    local node_bin="${3:-}"
    local service_target="/etc/systemd/system/managed-deploy-agent.service"
    local service_source="${toolkit_dir}/systemd/managed-deploy-agent.service.example"

    if [ -z "${node_bin}" ]; then
        node_bin="$(command -v node 2>/dev/null || true)"
    fi
    if [ -z "${node_bin}" ]; then
        node_bin="/usr/bin/node"
    fi
    if [ ! -x "${node_bin}" ]; then
        die "node binary not executable at ${node_bin}"
    fi

    if [ ! -f "${service_source}" ]; then
        die "Missing systemd template at ${service_source}"
    fi

    sed -e "s|__RELEASEPANEL_TOOLKIT_DIR__/runner|${runner_dir}|g" \
        -e "s|__RELEASEPANEL_TOOLKIT_DIR__|${toolkit_dir}|g" \
        -e "s|__RUNNER_DIR__|${runner_dir}|g" \
        -e "s|__NODE_BIN__|${node_bin}|g" \
        "${service_source}" > "${service_target}"

    if grep -qE '__[A-Z][A-Z0-9_]*__' "${service_target}"; then
        die "Unreplaced placeholders in ${service_target}"
    fi
    log "Systemd unit: ${service_target}"
}

join_normalize_token() {
    local t="$1"
    t="${t//$'\r'/}"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys; print(sys.argv[1].strip())' "${t}"
        return
    fi
    printf '%s' "${t}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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

    if [ "${NON_INTERACTIVE}" -eq 1 ]; then
        [ -n "${PANEL_URL}" ] || die "Missing --panel-url= or MANAGED_AGENT_PANEL_URL (non-interactive)."
    fi

    ensure_git
    install_or_refresh_clone

    TOOLKIT="${INSTALL_ROOT}/toolkit"
    [ -f "${INSTALL_ROOT}/server.js" ] || die "${INSTALL_ROOT}/server.js missing — clone or sync failed."
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

    if [ "${SKIP_JOIN}" -eq 0 ]; then
        JOIN_TOKEN="$(join_normalize_token "${JOIN_TOKEN}")"
        [ -n "${JOIN_TOKEN}" ] || die "Missing --join-token= or MANAGED_AGENT_JOIN_TOKEN (required for new registration)."
    fi

    export RELEASEPANEL_TOOLKIT_DIR="${TOOLKIT}"
    export MANAGED_AGENT_PANEL_URL="${PANEL_URL}"
    export RELEASEPANEL_PANEL_URL="${PANEL_URL}"
    export NON_INTERACTIVE
    if [ -n "${JOIN_TOKEN}" ]; then
        export MANAGED_AGENT_JOIN_TOKEN="${JOIN_TOKEN}"
        export RELEASEPANEL_JOIN_TOKEN="${JOIN_TOKEN}"
    fi

    log "Installing Node dependencies (${INSTALL_ROOT})…"
    agent_install_node_modules "${INSTALL_ROOT}"

    secure_install_root_permissions

    if command -v systemctl >/dev/null 2>&1; then
        NODE_BIN_FOR_UNIT="$(command -v node 2>/dev/null || true)"
        [ -n "${NODE_BIN_FOR_UNIT}" ] || die "node not found on PATH (cannot write systemd unit)."
        log "Using Node at: ${NODE_BIN_FOR_UNIT} (systemd ExecStart)"
        write_managed_agent_systemd_unit "${INSTALL_ROOT}" "${TOOLKIT}" "${NODE_BIN_FOR_UNIT}"
    else
        warn "systemd not found — skipping systemd unit and service."
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
        printf '\n  Foreground:\n' >&2
        printf '    cd %q\n' "${INSTALL_ROOT}" >&2
        printf '    exec node server.js\n' >&2
        printf '\n' >&2
        connectivity_hint
        warn "Firewall: allow outbound HTTPS to your panel."
        log "Done (no systemd)."
        exit 0
    fi

    log "Starting agent service…"
    systemctl daemon-reload
    systemctl enable managed-deploy-agent
    if ! systemctl restart managed-deploy-agent; then
        warn "systemctl restart failed; retrying in 2s…"
        sleep 2
        systemctl restart managed-deploy-agent || die "managed-deploy-agent failed to restart. journalctl -u managed-deploy-agent -n 50 --no-pager"
    fi

    log "Agent service is active."
    connectivity_hint
    warn "Firewall: allow outbound HTTPS to your panel."
    log "Done."
    printf '  • Service: %s\n' "$(systemctl is-active managed-deploy-agent 2>/dev/null || echo unknown)"
    printf '\n'
}

main "$@"
