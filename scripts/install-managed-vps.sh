#!/usr/bin/env bash
set -Eeuo pipefail

# Customer VPS entrypoint: ReleasePanel "Servers" bootstrap pipes `curl … | bash`.
# Clones the public agent bundle (runner + vendor toolkit/) then runs bootstrap-runner.
# Canonical copy lives in releasepanel-deploy; publish to releasepanel-runner via
# scripts/publish-releasepanel-runner.sh.
#
# Expected env (see ServerController::runnerInstallCommand):
#   MANAGED_AGENT_PANEL_URL, MANAGED_AGENT_SERVER_ID, MANAGED_AGENT_RUNNER_KEY
# Optional:
#   MANAGED_AGENT_REPO_URL / RELEASEPANEL_RUNNER_REPO_HTTPS — git clone URL
#   MANAGED_AGENT_REPO_BRANCH / RELEASEPANEL_RUNNER_BRANCH — default main
#   MANAGED_AGENT_INSTALL_ROOT / MANAGED_AGENT_INSTALL_DIR — default /opt/managed-deploy-agent

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

if [ "$(id -u)" -ne 0 ]; then
    echo "[install-managed-vps] ERROR: run as root." >&2
    exit 1
fi

DEFAULT_REPO="${MANAGED_AGENT_REPO_URL:-${RELEASEPANEL_RUNNER_REPO_HTTPS:-https://github.com/EdwardSoaresJr/releasepanel-runner.git}}"
DEFAULT_BRANCH="${MANAGED_AGENT_REPO_BRANCH:-${RELEASEPANEL_RUNNER_BRANCH:-main}}"
INSTALL_ROOT="${MANAGED_AGENT_INSTALL_ROOT:-${MANAGED_AGENT_INSTALL_DIR:-/opt/managed-deploy-agent}}"
TOOLKIT="${INSTALL_ROOT}/toolkit"

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

# Before the repo exists: same mirror + IPv4/timeout bootstrap as scripts/install.sh (_rp_git_bootstrap_apt_prepare).
_rp_managed_vps_bootstrap_apt_prepare() {
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

install_minimal_dependencies() {
    echo "[install-managed-vps] Installing minimal dependencies (git, curl)…"
    _rp_managed_vps_bootstrap_apt_prepare || true
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update -y
    apt-get install -y \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        git curl ca-certificates openssh-client
}

install_or_refresh_clone() {
    if [ -d "${INSTALL_ROOT}/.git" ]; then
        echo "[install-managed-vps] Existing clone at ${INSTALL_ROOT}; fetching latest ${DEFAULT_BRANCH}…"
        git -C "${INSTALL_ROOT}" fetch --depth 1 origin "${DEFAULT_BRANCH}" 2>/dev/null || true
        git -C "${INSTALL_ROOT}" checkout "${DEFAULT_BRANCH}" 2>/dev/null || true
        git -C "${INSTALL_ROOT}" pull --ff-only origin "${DEFAULT_BRANCH}" 2>/dev/null || {
            echo "[install-managed-vps] WARN: git pull failed; continuing with on-disk tree." >&2
        }
        return 0
    fi

    if [ -e "${INSTALL_ROOT}" ]; then
        echo "[install-managed-vps] ERROR: ${INSTALL_ROOT} exists but is not a git clone." >&2
        echo "[install-managed-vps] Move it aside or set MANAGED_AGENT_INSTALL_ROOT / MANAGED_AGENT_INSTALL_DIR to an empty path." >&2
        exit 1
    fi

    echo "[install-managed-vps] Cloning ${DEFAULT_REPO} (${DEFAULT_BRANCH}) → ${INSTALL_ROOT}…"
    install -d -m 0755 "$(dirname "${INSTALL_ROOT}")"
    git clone --depth 1 --branch "${DEFAULT_BRANCH}" "${DEFAULT_REPO}" "${INSTALL_ROOT}"
}

if command -v apt-get >/dev/null 2>&1; then
    install_minimal_dependencies
else
    echo "[install-managed-vps] WARN: apt-get not found; ensure git and curl are installed." >&2
fi

install_or_refresh_clone

if [ ! -f "${INSTALL_ROOT}/server.js" ]; then
    echo "[install-managed-vps] ERROR: ${INSTALL_ROOT}/server.js missing after clone." >&2
    exit 1
fi

if [ ! -f "${TOOLKIT}/scripts/bootstrap-runner.sh" ]; then
    echo "[install-managed-vps] ERROR: toolkit missing at ${TOOLKIT}/scripts/bootstrap-runner.sh." >&2
    echo "[install-managed-vps] Use the public agent repo that vendors toolkit/ (see releasepanel-runner README)." >&2
    exit 1
fi

if [ -f "${TOOLKIT}/scripts/assert-fresh-managed-server.sh" ]; then
    bash "${TOOLKIT}/scripts/assert-fresh-managed-server.sh"
fi

export RELEASEPANEL_TOOLKIT_DIR="${TOOLKIT}"
export MANAGED_AGENT_TOOLKIT_DIR="${TOOLKIT}"
cd "${TOOLKIT}"
exec bash scripts/bootstrap-runner.sh
