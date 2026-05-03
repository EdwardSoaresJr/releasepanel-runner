#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

readonly DEPLOY_ROOT="/opt"
readonly DEFAULT_RUNNER_BUNDLE_HTTPS="https://github.com/EdwardSoaresJr/managed-deploy-agent.git"
readonly RUNNER_REPO_DIR="${MANAGED_AGENT_INSTALL_DIR:-${DEPLOY_ROOT}/managed-deploy-agent}"
readonly RUNNER_REPO_HTTPS="${MANAGED_AGENT_RUNNER_REPO_HTTPS:-${RELEASEPANEL_RUNNER_REPO_HTTPS:-${DEFAULT_RUNNER_BUNDLE_HTTPS}}}"

log() {
    printf '%s\n' "[managed-deploy-agent-install] $*"
}

fail() {
    printf '%s\n' "[managed-deploy-agent-install] ERROR: $*" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Run as root, for example: sudo -i"
    fi
}

install_minimal_dependencies() {
    log "Installing minimal dependencies (git, curl)..."
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update -y
    apt-get install -y \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        git curl ca-certificates openssh-client
}

clone_public_runner_bundle() {
    log "Cloning or updating public agent into ${RUNNER_REPO_DIR}"

    export GIT_TERMINAL_PROMPT=0

    mkdir -p "${DEPLOY_ROOT}"

    if [ -d "${RUNNER_REPO_DIR}/.git" ]; then
        log "Repository present; pulling --ff-only."
        git -c credential.helper= -C "${RUNNER_REPO_DIR}" pull --ff-only || fail "git pull failed for ${RUNNER_REPO_DIR}"
    else
        if [ -e "${RUNNER_REPO_DIR}" ]; then
            fail "${RUNNER_REPO_DIR} exists but is not a git repository"
        fi
        git -c credential.helper= clone "${RUNNER_REPO_HTTPS}" "${RUNNER_REPO_DIR}" \
            || fail "HTTPS clone failed. Repository must be public, or set MANAGED_AGENT_RUNNER_REPO_HTTPS to a public mirror."
    fi

    if [ ! -f "${RUNNER_REPO_DIR}/toolkit/scripts/bootstrap-runner.sh" ]; then
        fail "Checkout missing toolkit/scripts/bootstrap-runner.sh — verify MANAGED_AGENT_RUNNER_REPO_HTTPS points at this agent repository."
    fi
}

main() {
    log "Starting customer VPS install (connects this server to your control plane)."
    log "This installer expects a fresh Ubuntu server with no existing nginx/apache/caddy/lighttpd stack."
    log "Override only if you know the risks: MANAGED_AGENT_SKIP_FRESH_SERVER_CHECK=1"
    require_root
    install_minimal_dependencies
    clone_public_runner_bundle
    bash "${RUNNER_REPO_DIR}/toolkit/scripts/assert-fresh-managed-server.sh"
    export RELEASEPANEL_TOOLKIT_DIR="${RUNNER_REPO_DIR}/toolkit"
    export MANAGED_AGENT_TOOLKIT_DIR="${RUNNER_REPO_DIR}/toolkit"
    cd "${RUNNER_REPO_DIR}/toolkit"
    exec bash scripts/bootstrap-runner.sh
}

main "$@"
