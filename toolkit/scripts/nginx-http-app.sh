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
require_env_value RELEASEPANEL_SERVER_NAME

cp "${RELEASEPANEL_TOOLKIT_DIR}/nginx/rate-limits.conf.example" /etc/nginx/conf.d/releasepanel-rate-limits.conf
ensure_php_fpm_socket

site_name="${RELEASEPANEL_NGINX_SITE_BASENAME}"
target="/etc/nginx/sites-available/${site_name}-http-app.conf"
enabled="/etc/nginx/sites-enabled/${site_name}-http-app.conf"
nginx_names="$(nginx_server_names)"

log "Writing HTTP-only nginx config for ${RELEASEPANEL_SERVER_NAME} (no TLS yet)."
sed \
    -e "s#__RELEASEPANEL_SERVER_NAME__#${RELEASEPANEL_SERVER_NAME}#g" \
    -e "s#__RELEASEPANEL_NGINX_SERVER_NAMES__#${nginx_names}#g" \
    -e "s#__RELEASEPANEL_BASE__#${RELEASEPANEL_BASE}#g" \
    -e "s#__RELEASEPANEL_PHP_VERSION__#${RELEASEPANEL_PHP_VERSION}#g" \
    -e "s#__RELEASEPANEL_PHP_FPM_SOCK__#${RELEASEPANEL_PHP_FPM_SOCK}#g" \
    -e "s#__RELEASEPANEL_NGINX_LOG_BASENAME__#${site_name}#g" \
    "${RELEASEPANEL_TOOLKIT_DIR}/nginx/releasepanel-http-app.conf.example" > "${target}"
validate_nginx_domain_file "${target}"

rm -f "/etc/nginx/sites-enabled/${site_name}" \
    "/etc/nginx/sites-enabled/${site_name}-acme.conf" \
    "/etc/nginx/sites-enabled/${site_name}-ssl" \
    "/etc/nginx/sites-enabled/${site_name}-redirect" \
    "/etc/nginx/sites-enabled/${site_name}-http.conf" \
    "/etc/nginx/sites-enabled/${site_name}-https.conf" \
    /etc/nginx/sites-enabled/default \
    /etc/nginx/sites-enabled/releasepanel-ssl \
    /etc/nginx/sites-enabled/releasepanel-redirect \
    /etc/nginx/sites-enabled/releasepanel-http.conf \
    /etc/nginx/sites-enabled/releasepanel-https.conf
ln -sfn "${target}" "${enabled}"

nginx -t
systemctl reload nginx

log "HTTP app nginx config installed."
