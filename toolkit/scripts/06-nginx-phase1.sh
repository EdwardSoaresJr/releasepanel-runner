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

site_name="${RELEASEPANEL_NGINX_SITE_BASENAME}"
target="/etc/nginx/sites-available/${site_name}-acme.conf"
enabled="/etc/nginx/sites-enabled/${site_name}-acme.conf"
nginx_names="$(nginx_server_names)"

echo "[releasepanel] Step: Writing temporary ACME challenge nginx config"
cat > "${target}" <<EOF
server {
    listen 80;
    server_name ${nginx_names};

    root ${RELEASEPANEL_BASE}/current/public;

    access_log /var/log/nginx/${site_name}-access.log;
    error_log /var/log/nginx/${site_name}-error.log;

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

if [ ! -s "${target}" ]; then
    echo "[error] ACME nginx config file is empty"
    exit 1
fi
validate_nginx_domain_file "${target}"

echo "[releasepanel] Step: Enabling ACME challenge site"
rm -f "/etc/nginx/sites-enabled/${site_name}" \
    "/etc/nginx/sites-enabled/${site_name}-ssl" \
    "/etc/nginx/sites-enabled/${site_name}-redirect" \
    "/etc/nginx/sites-enabled/${site_name}-http.conf" \
    "/etc/nginx/sites-enabled/${site_name}-https.conf" \
    /etc/nginx/sites-enabled/default \
    /etc/nginx/sites-enabled/releasepanel-ssl \
    /etc/nginx/sites-enabled/releasepanel-redirect \
    /etc/nginx/sites-enabled/releasepanel-http.conf \
    /etc/nginx/sites-enabled/releasepanel-https.conf
ln -sf "${target}" "${enabled}"

echo "[releasepanel] Step: Testing nginx config"
if nginx -t; then
    echo "[releasepanel] Step: Reloading nginx"
    systemctl reload nginx
else
    echo "[error] nginx config invalid"
    exit 1
fi

log "Temporary ACME challenge nginx config installed for ${RELEASEPANEL_SERVER_NAME}; run SSL finalization next."
