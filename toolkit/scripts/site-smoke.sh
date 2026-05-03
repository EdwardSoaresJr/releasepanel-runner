#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=site-runner-common.sh
. "${SCRIPT_DIR}/site-runner-common.sh"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_site_env_args "$@"
set -- "${SITE_ENV_NAME}"
parse_deploy_env_as_first_arg "${1}"
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

check "nginx config" nginx -t
check "HTTP responds or redirects" local_http_redirect_check true
check "php-fpm socket" test -S "/run/php/php${RELEASEPANEL_PHP_VERSION}-fpm.sock"
check "current symlink exists" test -L "${RELEASEPANEL_CURRENT}"
check "vendor/autoload.php exists" test -f "${RELEASEPANEL_CURRENT}/vendor/autoload.php"
case "${RELEASEPANEL_SMOKE_REQUIRE_HTTPS:-true}" in
    0 | false | FALSE | no | NO | off | OFF)
        check "HTTP app health response" local_http_check true
        ;;
    *)
        check "HTTPS app health response" local_https_check true
        ;;
esac

if [ "${failures}" -gt 0 ]; then
    fail "${failures} smoke test(s) failed."
fi

log "Site smoke tests passed."
