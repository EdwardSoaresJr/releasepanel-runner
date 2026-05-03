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

cert="/etc/letsencrypt/live/${RELEASEPANEL_SERVER_NAME}/fullchain.pem"
[ -f "${cert}" ] || fail "Certificate missing at ${cert}. Run 07-certbot-ssl.sh first."

install -d -m 0755 /etc/letsencrypt
if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
    warn "Certbot nginx SSL options file is missing; writing ReleasePanel fallback."
    cat > /etc/letsencrypt/options-ssl-nginx.conf <<'EOF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
EOF
fi

cp "${RELEASEPANEL_TOOLKIT_DIR}/nginx/rate-limits.conf.example" /etc/nginx/conf.d/releasepanel-rate-limits.conf
ensure_php_fpm_socket

site_name="${RELEASEPANEL_NGINX_SITE_BASENAME}"
target="/etc/nginx/sites-available/${site_name}-https.conf"
enabled="/etc/nginx/sites-enabled/${site_name}-https.conf"
nginx_names="$(nginx_server_names)"

log "Writing final HTTPS nginx config for ${RELEASEPANEL_SERVER_NAME}."
sed \
    -e "s#__RELEASEPANEL_SERVER_NAME__#${RELEASEPANEL_SERVER_NAME}#g" \
    -e "s#__RELEASEPANEL_NGINX_SERVER_NAMES__#${nginx_names}#g" \
    -e "s#__RELEASEPANEL_BASE__#${RELEASEPANEL_BASE}#g" \
    -e "s#__RELEASEPANEL_PHP_VERSION__#${RELEASEPANEL_PHP_VERSION}#g" \
    -e "s#__RELEASEPANEL_PHP_FPM_SOCK__#${RELEASEPANEL_PHP_FPM_SOCK}#g" \
    -e "s#__RELEASEPANEL_NGINX_LOG_BASENAME__#${site_name}#g" \
    "${RELEASEPANEL_TOOLKIT_DIR}/nginx/releasepanel-https.conf.example" > "${target}"
validate_nginx_domain_file "${target}"

if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
    warn "Certbot DH params file is missing; removing ssl_dhparam from nginx config."
    sed -i '/^[[:space:]]*ssl_dhparam[[:space:]]/d' "${target}"
fi

rm -f "/etc/nginx/sites-enabled/${site_name}" \
    "/etc/nginx/sites-enabled/${site_name}-acme.conf" \
    "/etc/nginx/sites-enabled/${site_name}-ssl" \
    "/etc/nginx/sites-enabled/${site_name}-redirect" \
    "/etc/nginx/sites-enabled/${site_name}-http.conf" \
    "/etc/nginx/sites-enabled/${site_name}-http-app.conf" \
    /etc/nginx/sites-enabled/default \
    /etc/nginx/sites-enabled/releasepanel-ssl \
    /etc/nginx/sites-enabled/releasepanel-redirect \
    /etc/nginx/sites-enabled/releasepanel-http.conf \
    /etc/nginx/sites-enabled/releasepanel-https.conf
ln -sfn "${target}" "${enabled}"

nginx -t
systemctl reload nginx

log "Final HTTPS nginx config installed."
