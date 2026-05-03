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
if [ -z "${RELEASEPANEL_SSL_EMAIL:-}" ]; then
    fail "RELEASEPANEL_SSL_EMAIL is not set. Add it to the toolkit site env (file: ${RELEASEPANEL_DEPLOY_ENV:-deploy.env}) — required for Certbot --email."
fi

server_ip="$(current_public_ip)"
dns_ips="$(domain_ips "${RELEASEPANEL_SERVER_NAME}")"
domain_regex="${RELEASEPANEL_SERVER_NAME//./\\.}"
certbot_domains=(-d "${RELEASEPANEL_SERVER_NAME}")
extra_domain=""
cert="/etc/letsencrypt/live/${RELEASEPANEL_SERVER_NAME}/fullchain.pem"

log "Server public IP: ${server_ip:-unknown}"
log "DNS A records for ${RELEASEPANEL_SERVER_NAME}: ${dns_ips:-none}"

if [ -n "${server_ip}" ] && ! printf '%s\n' "${dns_ips}" | grep -qx "${server_ip}"; then
    fail "DNS for ${RELEASEPANEL_SERVER_NAME} does not point to this server yet. Do not run Certbot."
fi

if ! grep -RE "^[[:space:]]*server_name[[:space:]].*\\b${domain_regex}\\b.*;[[:space:]]*$" /etc/nginx/sites-enabled /etc/nginx/sites-available >/dev/null 2>&1; then
    fail "No nginx ACME challenge block with server_name ${RELEASEPANEL_SERVER_NAME}. Run 06-nginx-phase1.sh first."
fi

for extra_domain in ${RELEASEPANEL_CERTBOT_EXTRA_DOMAINS}; do
    if [[ "${extra_domain}" == *"*"* ]]; then
        warn "Skipping wildcard Certbot domain ${extra_domain}; HTTP-01 cannot issue wildcard certificates. Use DNS validation and install the wildcard certificate manually."
        continue
    fi

    certbot_domains+=(-d "${extra_domain}")
done

nginx -t

if [ -f "${cert}" ]; then
    log "Certificate already exists at ${cert}; skipping issuance."
    systemctl reload nginx
    exit 0
fi

log "Running Certbot for ${RELEASEPANEL_SERVER_NAME}."
certbot certonly --webroot \
    -w "${RELEASEPANEL_BASE}/current/public" \
    "${certbot_domains[@]}" \
    --email "${RELEASEPANEL_SSL_EMAIL}" \
    --agree-tos \
    --no-eff-email

log "Certbot complete."
