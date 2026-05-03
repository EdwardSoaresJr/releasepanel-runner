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

failures=0

check() {
    local label="$1"
    shift

    if "$@"; then
        printf '\033[1;32m[ok]\033[0m %s\n' "${label}"
    else
        printf '\033[1;31m[fail]\033[0m %s\n' "${label}" >&2
        failures=$((failures + 1))
    fi
}

current_release=""
[ -L "${RELEASEPANEL_CURRENT}" ] && current_release="$(readlink -f "${RELEASEPANEL_CURRENT}")"

check "nginx config" nginx -t
check "php-fpm service detected" php_fpm_service
check "redis ping" redis-cli ping
check "composer available" run_as_app_user "$(releasepanel_composer_path)" --version --no-ansi
check "node available" node --version
check "npm available" npm --version
check "current symlink exists" test -L "${RELEASEPANEL_CURRENT}"
check "vendor/autoload.php exists" test -f "${RELEASEPANEL_CURRENT}/vendor/autoload.php"

if [ -n "${current_release}" ] && [ -f "${current_release}/vendor/autoload.php" ]; then
    check "artisan about" artisan_in_release "${current_release}" about --no-interaction
    check "artisan route:list" artisan_in_release "${current_release}" route:list --no-interaction
    check "queue config is readable" artisan_in_release "${current_release}" queue:failed --no-interaction
    check "schedule list" artisan_in_release "${current_release}" schedule:list --no-interaction
fi

if [ "${RELEASEPANEL_ENV}" != "releasepanel" ] && [ -n "${RELEASEPANEL_SERVER_NAME}" ]; then
    check "HTTPS app health response" local_https_check true
elif [ "${RELEASEPANEL_ENV}" = "releasepanel" ]; then
    warn "Skipping public URL smoke for ReleasePanel; nginx local checks cover the ReleasePanel deploy."
fi

if [ -n "${RELEASEPANEL_OPS_HEALTH_BASE_URL}" ] && [ -n "${OPS_INTERNAL_HEALTH_SECRET}" ]; then
    check "ops internal health response" curl -fsS --max-time 15 -H "Host: ${RELEASEPANEL_SERVER_NAME}" -H "X-RELEASEPANEL-OPS-SECRET: ${OPS_INTERNAL_HEALTH_SECRET}" "${RELEASEPANEL_OPS_HEALTH_BASE_URL}"
fi

if [ "${RELEASEPANEL_ENV}" != "releasepanel" ] && [ -n "${RELEASEPANEL_SERVER_NAME}" ] && command -v openssl >/dev/null 2>&1; then
    check "SSL certificate expiry" bash -lc "echo | openssl s_client -servername '${RELEASEPANEL_SERVER_NAME}' -connect '${RELEASEPANEL_SERVER_NAME}:443' 2>/dev/null | openssl x509 -noout -dates"
elif [ "${RELEASEPANEL_ENV}" = "releasepanel" ]; then
    warn "Skipping SSL certificate smoke for ReleasePanel."
fi

if [ "${RELEASEPANEL_ENV}" != "releasepanel" ]; then
    check "wkhtmltopdf version" wkhtmltopdf --version
else
    warn "Skipping wkhtmltopdf smoke for ReleasePanel."
fi

if [ "${failures}" -gt 0 ]; then
    fail "${failures} smoke test(s) failed."
fi

log "All smoke tests passed."
