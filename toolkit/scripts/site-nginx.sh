#!/usr/bin/env bash
set -Eeuo pipefail

RELEASEPANEL_TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=site-runner-common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-runner-common.sh"
# shellcheck source=../lib/common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/lib/common.sh"

load_site_env_args "$@"

set -- "${SITE_ENV_NAME}"
if ! parse_deploy_env_as_first_arg "${1:-}"; then
    echo "[error] Usage: ${0##*/} <site> <environment>" >&2
    exit 2
fi
shift
load_env

tls_mode="${RELEASEPANEL_TLS_MODE:-}"
if [ -z "${tls_mode}" ]; then
    if [ -f "/etc/letsencrypt/live/${RELEASEPANEL_SERVER_NAME}/fullchain.pem" ]; then
        tls_mode="letsencrypt"
    elif [ -f "/etc/ssl/releasepanel/${RELEASEPANEL_SERVER_NAME}/fullchain.pem" ]; then
        tls_mode="self-signed"
    else
        tls_mode="none"
    fi
fi

case "${tls_mode}" in
    none | http)
        exec bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/nginx-http-app.sh" "${SITE_ENV_NAME}"
        ;;
    self-signed)
        exec bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/08-nginx-https-selfsigned.sh" "${SITE_ENV_NAME}"
        ;;
    *)
        exec bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/08-nginx-final.sh" "${SITE_ENV_NAME}"
        ;;
esac
