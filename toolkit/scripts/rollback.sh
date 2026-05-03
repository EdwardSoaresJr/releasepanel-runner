#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root
if ! parse_deploy_env_as_first_arg "${1:-}"; then
    fail "Usage: ${0##*/} <site-env> [--yes] [release]"
fi
shift
load_env

target="${1:-}"
assume_yes=false

if [ "${target}" = "--yes" ]; then
    assume_yes=true
    shift
    target="${1:-}"
fi

if [ ! -d "${RELEASEPANEL_RELEASES}" ]; then
    fail "No releases directory at ${RELEASEPANEL_RELEASES}."
fi

if [ -z "${target}" ]; then
    echo "Available releases:"
    find "${RELEASEPANEL_RELEASES}" -mindepth 1 -maxdepth 1 -type d | sort -r | nl -w2 -s'. '
    echo
    previous="$(find "${RELEASEPANEL_RELEASES}" -mindepth 1 -maxdepth 1 -type d | sort -r | sed -n '2p')"
    [ -n "${previous}" ] || fail "No previous release found."
    target="${previous}"
else
    if [[ "${target}" != /* ]]; then
        target="${RELEASEPANEL_RELEASES}/${target}"
    fi
fi

[ -d "${target}" ] || fail "Target release does not exist: ${target}"
[ -f "${target}/vendor/autoload.php" ] || fail "Target release is missing vendor/autoload.php: ${target}"

if [ "${assume_yes}" != true ] && ! confirm "Switch current to ${target}? No migrations will be rolled back."; then
    fail "Rollback aborted."
fi

ln -sfn "${target}" "${RELEASEPANEL_CURRENT}.new"
mv -Tf "${RELEASEPANEL_CURRENT}.new" "${RELEASEPANEL_CURRENT}"
chown -h "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_CURRENT}"

sha="$(run_as_app_user_in "${target}" git rev-parse HEAD 2>/dev/null || echo unknown)"
write_deploy_stamp "${target}" "rollback" "${sha}"

reload_php_fpm
restart_workers

log "Rollback complete: ${target}"
