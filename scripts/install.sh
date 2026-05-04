#!/usr/bin/env bash
# Panel/bootstrap entrypoint ONLY: clones or updates releasepanel-runner, then runs real installer in-repo.
# Stable URL: https://YOUR_PANEL/install.sh  — all logic lives in toolkit/scripts/install-agent-from-repo.sh
#
#   curl -fsSL --proto '=https' --tlsv1.2 'https://YOUR_PANEL/install.sh' | sudo bash -s -- \
#     --panel-url='https://YOUR_PANEL' \
#     --account-key='acct_…'
set -Eeuo pipefail

readonly INSTALL_ROOT="${MANAGED_AGENT_INSTALL_ROOT:-/opt/managed-deploy-agent}"
readonly DEFAULT_REPO="${MANAGED_AGENT_REPO_URL:-${RELEASEPANEL_RUNNER_REPO:-${RELEASEPANEL_RUNNER_REPO_HTTPS:-https://github.com/EdwardSoaresJr/releasepanel-runner.git}}}"
readonly DEFAULT_BRANCH="${MANAGED_AGENT_REPO_BRANCH:-${RELEASEPANEL_RUNNER_BRANCH:-main}}"

PANEL_URL="${MANAGED_AGENT_PANEL_URL:-${RELEASEPANEL_PANEL_URL:-}}"
INSTALL_KEY="${MANAGED_AGENT_ACCOUNT_KEY:-${RELEASEPANEL_AGENT_ACCOUNT_KEY:-${MANAGED_AGENT_PANEL_INSTALL_KEY:-${RELEASEPANEL_INSTALL_KEY:-}}}}"
INSTALL_AGENT=1
NON_INTERACTIVE=0

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

# Bootstrap path before releasepanel-runner exists: mirror probe + IPv4/timeouts aligned with scripts/lib/apt-optimizations.sh.
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

# Mirrors scripts/lib/apt-optimizations.sh apt_update_safe (runner tree not cloned yet).
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

usage() {
    cat >&2 <<'EOF'
ReleasePanel bootstrap: clones releasepanel-runner, then installs the agent from the repo (single source of truth).

Usage:
  curl -fsSL --proto '=https' --tlsv1.2 'https://YOUR_PANEL/install.sh' | sudo bash -s -- \\
    --panel-url='https://YOUR_PANEL' \\
    --account-key='acct_…'

Options:
  --panel-url=URL       Control plane base URL (required for new installs)
  --account-key=SECRET  Organization install key (X-ACCOUNT-INSTALL-KEY); not kept in agent .env after register
  --install-key=SECRET  Alias for --account-key
  --non-interactive     Fail if panel URL missing when needed
  --ssh-only            Skip agent; print SSH-only hints
  --agent               Install agent (default)
  --help

Runner key is generated on the VPS (register-server.sh) — never pass --runner-key here.
Optional: --non-interactive for scripted installs. Override clone URL: MANAGED_AGENT_REPO_URL or RELEASEPANEL_RUNNER_REPO (default: public HTTPS GitHub).
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --panel-url=*)
                PANEL_URL="${1#*=}"
                shift
                ;;
            --account-key=*)
                INSTALL_KEY="${1#*=}"
                shift
                ;;
            --install-key=*)
                INSTALL_KEY="${1#*=}"
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

    inner_script="${INSTALL_ROOT}/toolkit/scripts/install-agent-from-repo.sh"

    if [ -d "${INSTALL_ROOT}/.git" ]; then
        log "Updating agent repo at ${INSTALL_ROOT} (${DEFAULT_BRANCH}) — resetting to origin/${DEFAULT_BRANCH} (drops local commits; keeps untracked files like .env)…"
        if git -C "${INSTALL_ROOT}" remote get-url origin >/dev/null 2>&1; then
            git -C "${INSTALL_ROOT}" remote set-url origin "${DEFAULT_REPO}"
        else
            git -C "${INSTALL_ROOT}" remote add origin "${DEFAULT_REPO}"
        fi
        if ! git -C "${INSTALL_ROOT}" fetch --depth 1 origin "${DEFAULT_BRANCH}"; then
            die "git fetch failed (network/SSH?). Fix connectivity, then re-run. Left unchanged: ${INSTALL_ROOT}"
        fi
        if ! git -C "${INSTALL_ROOT}" checkout -B "${DEFAULT_BRANCH}" "origin/${DEFAULT_BRANCH}"; then
            die "Could not sync to origin/${DEFAULT_BRANCH}. Try: cd ${INSTALL_ROOT} && git remote -v && git status. Or back up .env, remove ${INSTALL_ROOT}, and re-run the installer."
        fi
        secure_install_root_permissions
        trust_install_root_git
        if [ ! -f "${inner_script}" ]; then
            die "Synced repo is missing ${inner_script#"${INSTALL_ROOT}/"}. Check DEFAULT_REPO / branch (expecting releasepanel-runner ${DEFAULT_BRANCH}). Back up .env, rm -rf ${INSTALL_ROOT}, re-run."
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

    PANEL_URL="${PANEL_URL%/}"
    if [ -n "${PANEL_URL}" ]; then
        validate_panel_url "${PANEL_URL}"
    fi

    ensure_git
    install_or_refresh_clone

    local inner="${INSTALL_ROOT}/toolkit/scripts/install-agent-from-repo.sh"
    [ -x "${inner}" ] || chmod +x "${inner}" 2>/dev/null || true
    [ -f "${inner}" ] || die "Missing ${inner} — update releasepanel-runner (main) or fix clone URL."

    export MANAGED_AGENT_PANEL_URL="${PANEL_URL}"
    export RELEASEPANEL_PANEL_URL="${PANEL_URL}"
    export PANEL_URL
    if [ -n "${INSTALL_KEY}" ]; then
        export MANAGED_AGENT_ACCOUNT_KEY="${INSTALL_KEY}"
        export RELEASEPANEL_AGENT_ACCOUNT_KEY="${INSTALL_KEY}"
        export MANAGED_AGENT_PANEL_INSTALL_KEY="${INSTALL_KEY}"
        export RELEASEPANEL_INSTALL_KEY="${INSTALL_KEY}"
    fi
    export NON_INTERACTIVE

    if [ -z "${INSTALL_KEY}" ]; then
        warn "No --account-key= set. If this panel requires an organization install key, registration will fail until you add it (copy the full command from Connect server in the panel)."
    fi

    log "Starting in-repo installer…"
    exec bash "${inner}"
}

main "$@"
