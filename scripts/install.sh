#!/usr/bin/env bash
# Panel/bootstrap entrypoint ONLY: clones or updates releasepanel-runner, then runs real installer in-repo.
# Stable URL: https://YOUR_PANEL/install.sh  — all logic lives in toolkit/scripts/install-agent-from-repo.sh
#
#   curl -fsSL --proto '=https' --tlsv1.2 'https://YOUR_PANEL/install.sh' | sudo bash -s -- \
#     --non-interactive --panel-url='https://YOUR_PANEL' [--account-key='…']
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

usage() {
    cat >&2 <<'EOF'
ReleasePanel bootstrap: clones releasepanel-runner, then installs the agent from the repo (single source of truth).

Usage:
  curl -fsSL --proto '=https' --tlsv1.2 'https://YOUR_PANEL/install.sh' | sudo bash -s -- \
    --non-interactive --panel-url='https://YOUR_PANEL'

Options:
  --panel-url=URL       Control plane base URL (required for new installs)
  --account-key=SECRET  SaaS onboarding (X-ACCOUNT-INSTALL-KEY); not kept in agent .env after register
  --install-key=SECRET  Alias for --account-key
  --non-interactive     Fail if panel URL missing when needed
  --ssh-only            Skip agent; print SSH-only hints
  --agent               Install agent (default)
  --help

Runner key is generated on the server (register-server.sh); do not pass --runner-key for normal onboarding.
Override clone URL: MANAGED_AGENT_REPO_URL or RELEASEPANEL_RUNNER_REPO (default: public HTTPS GitHub).
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
        apt-get update -y
        apt-get install -y git ca-certificates
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
        log "Updating agent repo at ${INSTALL_ROOT} (${DEFAULT_BRANCH})…"
        if ! git -C "${INSTALL_ROOT}" fetch --depth 1 origin "${DEFAULT_BRANCH}" 2>/dev/null; then
            warn "Git fetch failed, recloning…"
            rm -rf "${INSTALL_ROOT}"
        else
            git -C "${INSTALL_ROOT}" checkout "${DEFAULT_BRANCH}" 2>/dev/null || true
            git -C "${INSTALL_ROOT}" pull --ff-only origin "${DEFAULT_BRANCH}" 2>/dev/null || warn "git pull failed; continuing on disk."
            secure_install_root_permissions
            trust_install_root_git
            return 0
        fi
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

    log "Starting in-repo installer…"
    exec bash "${inner}"
}

main "$@"
