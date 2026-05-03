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

base_dir="/etc/ssl/releasepanel/${RELEASEPANEL_SERVER_NAME}"
cert_file="${base_dir}/fullchain.pem"
key_file="${base_dir}/privkey.pem"

if [ -f "${cert_file}" ] && [ -f "${key_file}" ] && [ -s "${cert_file}" ] && [ -s "${key_file}" ]; then
    case "${RELEASEPANEL_FORCE_SELF_SIGNED_REGEN:-false}" in
        1 | true | TRUE | yes | YES) ;;
        *)
            log "Keeping existing self-signed certificate for ${RELEASEPANEL_SERVER_NAME} (${cert_file}). Set RELEASEPANEL_FORCE_SELF_SIGNED_REGEN=true to replace."
            exit 0
            ;;
    esac
fi

log "Generating self-signed TLS certificate for ${RELEASEPANEL_SERVER_NAME} (testing / no Let's Encrypt)."
install -d -m 0755 "${base_dir}"

if command -v openssl >/dev/null 2>&1 && openssl req -help 2>&1 | grep -qi 'addext'; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "${key_file}" \
        -out "${cert_file}" \
        -subj "/CN=${RELEASEPANEL_SERVER_NAME}/O=ReleasePanel-local" \
        -addext "subjectAltName=DNS:${RELEASEPANEL_SERVER_NAME}"
else
    warn "OpenSSL without -addext; certificate may lack SAN (use a recent OpenSSL for best browser behavior)."
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "${key_file}" \
        -out "${cert_file}" \
        -subj "/CN=${RELEASEPANEL_SERVER_NAME}/O=ReleasePanel-local"
fi

chown root:root "${cert_file}" "${key_file}"
chmod 0644 "${cert_file}"
chmod 0600 "${key_file}"

log "Wrote ${cert_file} and key (self-signed; browsers will warn until you trust the cert or switch to Let's Encrypt)."
