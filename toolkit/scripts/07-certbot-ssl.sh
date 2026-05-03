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
    deploy_env="${RELEASEPANEL_DEPLOY_ENV:-deploy.env}"
    fail "RELEASEPANEL_SSL_EMAIL is not set (Certbot requires a contact email). Edit ${deploy_env} and add: RELEASEPANEL_SSL_EMAIL=you@example.com — then re-run SSL finalization (e.g. releasepanel site ssl <site> <env>)."
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

for alias in ${RELEASEPANEL_SERVER_ALIASES:-}; do
    [ -z "${alias}" ] && continue
    if [ "${alias}" = "${RELEASEPANEL_SERVER_NAME}" ]; then
        continue
    fi
    certbot_domains+=(-d "${alias}")
done

nginx -t

skip_certbot=false
if [ -f "${cert}" ] && command -v openssl >/dev/null 2>&1; then
    issuer="$(openssl x509 -in "${cert}" -noout -issuer 2>/dev/null || echo '')"
    if grep -qi "Let's Encrypt" <<<"${issuer}"; then
        case "${RELEASEPANEL_CERTBOT_FORCE_REISSUE:-false}" in
            1 | true | TRUE | yes | YES)
                log "RELEASEPANEL_CERTBOT_FORCE_REISSUE=true; running Certbot despite existing certificate."
                ;;
            *)
                skip_certbot=true
                ;;
        esac
    else
        warn "File exists at ${cert} but it does not appear to be a Let's Encrypt certificate."
        warn "OpenSSL issuer: ${issuer}"
        warn "Certbot will run to replace it with a Let's Encrypt certificate."
    fi
elif [ -f "${cert}" ]; then
    warn "openssl not installed; cannot verify ${cert}. Skipping issuance. Install openssl and re-run if the browser still shows the wrong certificate."
    skip_certbot=true
fi

if [ "${skip_certbot}" = true ]; then
    log "Let's Encrypt certificate already present at ${cert}; skipping issuance."
    if command -v openssl >/dev/null 2>&1; then
        while IFS= read -r meta_line; do
            log "  ${meta_line}"
        done < <(openssl x509 -in "${cert}" -noout -subject -dates 2>/dev/null || true)
    fi
    nginx -t
    systemctl reload nginx
    exit 0
fi

log "Running Certbot for ${RELEASEPANEL_SERVER_NAME}."
certbot certonly --webroot \
    -w "${RELEASEPANEL_BASE}/current/public" \
    "${certbot_domains[@]}" \
    --cert-name "${RELEASEPANEL_SERVER_NAME}" \
    --email "${RELEASEPANEL_SSL_EMAIL}" \
    --agree-tos \
    --no-eff-email

log "Certbot complete."
