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
require_env_value RELEASEPANEL_REPO
require_composer

echo "[releasepanel] Step: Ensuring PHP-FPM matches RELEASEPANEL_PHP_VERSION (${RELEASEPANEL_PHP_VERSION})"
ensure_php_fpm_socket

ensure_app_layout

release="${RELEASEPANEL_RELEASES}/$(date +%Y%m%d%H%M%S)-initial"
RELEASE_PATH="${release}"
previous_current=""

if [ -L "${RELEASEPANEL_CURRENT}" ]; then
    previous_current="$(readlink -f "${RELEASEPANEL_CURRENT}")"
fi

echo "[releasepanel] Step: Cloning repository"
log "Cloning ${RELEASEPANEL_REPO} (${RELEASEPANEL_BRANCH}) into ${release}."
run_as_app_user git clone --branch "${RELEASEPANEL_BRANCH}" --single-branch "${RELEASEPANEL_REPO}" "${release}"
promote_app_subdir_release

echo "[releasepanel] Step: Linking shared .env and storage"
link_shared_paths
echo "[releasepanel] Step: Preparing release filesystem"
prepare_release_filesystem

comp_bin="$(releasepanel_composer_path)"
if [ -z "${comp_bin}" ] || [ ! -x "${comp_bin}" ]; then
    fail "composer missing at /usr/local/bin/composer — run: sudo bash ${SCRIPT_DIR}/install-composer-official.sh   or: sudo bash ${SCRIPT_DIR}/01-bootstrap.sh"
fi

echo "[releasepanel] Step: Verifying PHP CLI extensions (before composer)"
require_php_cli_extensions_for_deploy "${release}"

echo "[releasepanel] Step: Running composer install (${comp_bin})"
if ! run_as_app_user_in "${release}" "${comp_bin}" install --no-dev --prefer-dist --optimize-autoloader --no-scripts --no-interaction; then
    write_deploy_stamp "${release}" "failed-composer" "unknown"
    fail "Composer install failed. current symlink was not changed."
fi

validate_release_ready

detect_and_run_asset_build "${release}"

validate_release_ready

echo "[releasepanel] Step: Switching current symlink"
ln -sfn "${release}" "${RELEASEPANEL_CURRENT}.new"
mv -Tf "${RELEASEPANEL_CURRENT}.new" "${RELEASEPANEL_CURRENT}"
chown -h "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_CURRENT}"

sha="$(run_as_app_user_in "${release}" git rev-parse HEAD)"
write_deploy_stamp "${release}" "initial-success" "${sha}"

echo "[releasepanel] Step: Reloading PHP-FPM and workers"
reload_php_fpm
restart_workers

local_https_check

log "Initial deploy complete."
print_deploy_summary "${sha}"
if [ -n "${previous_current}" ]; then
    log "Previous current was ${previous_current}."
fi
warn "Edit ${RELEASEPANEL_SHARED}/.env before running migrations or accepting traffic."
warn "After editing .env, run: bash scripts/deploy.sh ${RELEASEPANEL_ENV} --skip-migrations"
