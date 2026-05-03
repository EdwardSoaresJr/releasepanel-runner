#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root
if ! parse_deploy_env_as_first_arg "${1:-}"; then
    fail "Usage: ${0##*/} <site-env>"
fi
shift
load_env

log "Running preflight checks."

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || fail "Expected Ubuntu. Found ${PRETTY_NAME:-unknown}."
    [ "${VERSION_ID:-}" = "24.04" ] || warn "Expected Ubuntu 24.04. Found ${PRETTY_NAME:-unknown}."
else
    warn "Could not read /etc/os-release."
fi

require_env_value RELEASEPANEL_REPO
require_env_value RELEASEPANEL_SERVER_NAME

log "Toolkit: ${RELEASEPANEL_TOOLKIT_DIR}"
log "App base: ${RELEASEPANEL_BASE}"
log "App user: ${RELEASEPANEL_APP_USER}"
log "Server name: ${RELEASEPANEL_SERVER_NAME}"
log "Repository: ${RELEASEPANEL_REPO}"

command -v apt-get >/dev/null 2>&1 || fail "apt-get not found."
command -v git >/dev/null 2>&1 || warn "git is not installed yet; bootstrap will install it."

if ! getent hosts github.com >/dev/null 2>&1; then
    warn "github.com DNS lookup failed; bootstrap may still work, but deploy repo/app repo cloning will not."
fi

if ! getent hosts "${RELEASEPANEL_SERVER_NAME}" >/dev/null 2>&1; then
    warn "${RELEASEPANEL_SERVER_NAME} DNS does not resolve from this server yet; finish DNS before SSL."
fi

available_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
if [ -n "${available_kb}" ] && [ "${available_kb}" -lt 5242880 ]; then
    warn "Less than 5GB free on /. Bootstrap/deploy may run out of disk."
fi

warn "Preflight intentionally does not require PHP, Composer, Nginx, Redis, Node, or Supervisor. Bootstrap installs those; status/deploy checks verify them afterward."

log "Preflight complete."
