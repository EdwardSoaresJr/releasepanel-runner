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

log "Creating application user and directory layout."

user_preexisted=false
if id "${RELEASEPANEL_APP_USER}" >/dev/null 2>&1; then
    user_preexisted=true
fi

if ! getent group "${RELEASEPANEL_FILE_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${RELEASEPANEL_FILE_GROUP}"
fi

if [ "${user_preexisted}" != true ]; then
    adduser --disabled-password --gecos "ReleasePanel deploy user" "${RELEASEPANEL_APP_USER}"
fi

usermod -aG "${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_APP_USER}"
usermod -aG "${RELEASEPANEL_FILE_GROUP}" www-data || true

mkdir -p "${RELEASEPANEL_BASE}/releases" "${RELEASEPANEL_BASE}/shared/storage"
touch "${RELEASEPANEL_BASE}/shared/.env"

full_tree=false
case "${RELEASEPANEL_FULL_TREE_PERMISSIONS:-}" in
    1 | true | TRUE | yes | YES)
        full_tree=true
        ;;
esac

if [ "${full_tree}" = true ] || [ "${user_preexisted}" != true ]; then
    log "Applying full-tree ownership and mode (first install or RELEASEPANEL_FULL_TREE_PERMISSIONS=${RELEASEPANEL_FULL_TREE_PERMISSIONS:-})."
    chown -R "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_BASE}"
    find "${RELEASEPANEL_BASE}" -type d -exec chmod 2775 {} \;
    find "${RELEASEPANEL_BASE}" -type f -exec chmod 664 {} \;
else
    log "Existing deploy user; fixing ownership on layout roots only (avoid scanning every release). Set RELEASEPANEL_FULL_TREE_PERMISSIONS=1 to chmod/chown the full tree."
    chown "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_BASE}" "${RELEASEPANEL_BASE}/releases" "${RELEASEPANEL_BASE}/shared"
    chmod 2775 "${RELEASEPANEL_BASE}" "${RELEASEPANEL_BASE}/releases" "${RELEASEPANEL_BASE}/shared"
fi

log "Created ${RELEASEPANEL_APP_USER} and ${RELEASEPANEL_BASE}."
