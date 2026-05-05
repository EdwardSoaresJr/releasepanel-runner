#!/usr/bin/env bash
#
# Create or update ReleasePanel panel admin without the fzf operator menu.
# Mirrors initial bootstrap prompts: Initial admin email + Initial admin password.
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[error] Run as root: sudo releasepanel create-admin" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASEPANEL_TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/lib/common.sh"

if [ -f "${RELEASEPANEL_TOOLKIT_DIR}/deploy.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${RELEASEPANEL_TOOLKIT_DIR}/deploy.env"
    set +a
fi

: "${RELEASEPANEL_PHP_VERSION:=${PHP_VERSION:-8.3}}"
RP_PHP_CLI="$(php_binary)"
RELEASEPANEL_APP_USER="${RELEASEPANEL_APP_USER:-releasepanel}"
RP_PANEL_CURRENT="${RELEASEPANEL_PANEL_CURRENT:-/var/www/sites/releasepanel-app/production/current}"

panel_create_admin_default_email() {
    local panel_root shared_env app_url host
    panel_root="$(cd "${RP_PANEL_CURRENT}/.." && pwd)"
    shared_env="${panel_root}/shared/.env"
    app_url=""
    if [ -f "${shared_env}" ]; then
        app_url="$(releasepanel_dotenv_get "${shared_env}" APP_URL 2>/dev/null || true)"
    fi
    host="localhost"
    if [ -n "${app_url}" ]; then
        host="${app_url#http://}"
        host="${host#https://}"
        host="${host%%/*}"
        host="${host%%:*}"
    fi
    if [ -z "${host}" ]; then
        host="localhost"
    fi
    printf 'admin@%s' "${host}"
}

main() {
    local admin_email admin_password

    if [ ! -f "${RP_PANEL_CURRENT}/artisan" ]; then
        echo "[error] Panel not found: ${RP_PANEL_CURRENT}/artisan" >&2
        echo "[hint] Set RELEASEPANEL_PANEL_CURRENT=/path/to/panel/current" >&2
        exit 1
    fi

    echo ""
    echo "=== Create or update panel admin (same prompts as initial bootstrap) ==="
    echo "Uses: releasepanel:create-admin — default display name Admin, default org + install key."
    echo "Pre-fill from environment: RELEASEPANEL_ADMIN_EMAIL, RELEASEPANEL_ADMIN_PASSWORD"
    echo ""

    admin_email="$(prompt_value RELEASEPANEL_ADMIN_EMAIL "Initial admin email" "$(panel_create_admin_default_email)")"
    admin_email="$(printf '%s' "${admin_email}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "${admin_email}" ] || [ "${admin_email}" = "${admin_email/@/}" ]; then
        echo "[error] Valid email required (must contain @)." >&2
        exit 1
    fi

    admin_password="$(prompt_secret RELEASEPANEL_ADMIN_PASSWORD "Initial admin password")"

    sudo -Hu "${RELEASEPANEL_APP_USER}" bash -lc "$(printf 'cd %q && RELEASEPANEL_BOOTSTRAP_ADMIN_PASSWORD=%q %q artisan releasepanel:create-admin %q --no-interaction' \
        "${RP_PANEL_CURRENT}" "${admin_password}" "${RP_PHP_CLI}" "${admin_email}")"
    admin_password=""
}

main "$@"
