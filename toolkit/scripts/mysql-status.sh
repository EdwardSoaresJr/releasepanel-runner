#!/usr/bin/env bash
#
# ReleasePanel MySQL health (control plane). Root useful for service checks.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"
if [ -f "${RELEASEPANEL_TOOLKIT_DIR}/deploy.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${RELEASEPANEL_TOOLKIT_DIR}/deploy.env"
    set +a
fi
: "${RELEASEPANEL_PHP_VERSION:=${PHP_VERSION:-8.3}}"
PHP_CLI="$(php_binary)"

BASE_PATH="/var/www/sites/releasepanel-app/production"

show_status() {
    echo "=== MySQL service ==="
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
            echo "MySQL/MariaDB: active"
        else
            echo "MySQL/MariaDB: not active (external DB may still be OK)"
        fi
    else
        echo "systemctl not available"
    fi

    if [ ! -f "${BASE_PATH}/current/artisan" ]; then
        echo "[warn] Panel not found at ${BASE_PATH}/current"
        exit 0
    fi

    echo ""
    echo "=== Laravel DB connection ==="
    sudo -u releasepanel bash -lc "cd $(printf '%q' "${BASE_PATH}/current") && $(printf '%q' "${PHP_CLI}") artisan tinker --execute=\"
        try {
            \\\$pdo = DB::connection()->getPdo();
            echo get_class(\\\$pdo).' | db='.DB::connection()->getDatabaseName().PHP_EOL;
        } catch (Throwable \\\$e) {
            echo 'DB connection failed: '.\\\$e->getMessage().PHP_EOL;
        }
    \"" 2>/dev/null || echo "[warn] connection check failed"

    echo ""
    echo "=== Migration status (first 30 lines) ==="
    sudo -u releasepanel bash -lc "cd $(printf '%q' "${BASE_PATH}/current") && $(printf '%q' "${PHP_CLI}") artisan migrate:status --no-interaction" 2>/dev/null | head -30 || echo "[warn] migrate:status failed"

    echo ""
    echo "=== Database size (information_schema) ==="
    sudo -u releasepanel bash -lc "cd $(printf '%q' "${BASE_PATH}/current") && $(printf '%q' "${PHP_CLI}") artisan tinker --execute=\"
        try {
            \\\$db = DB::connection()->getDatabaseName();
            \\\$r = DB::selectOne(
                'SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS mb FROM information_schema.tables WHERE table_schema = ?',
                [\\\$db]
            );
            echo 'Approx size: '.(\\\$r->mb ?? 'n/a').' MB'.PHP_EOL;
        } catch (Throwable \\\$e) {
            echo 'n/a'.PHP_EOL;
        }
    \"" 2>/dev/null || echo "n/a"

    echo ""
    echo "=== Slow query log (MySQL server) ==="
    if command -v mysql >/dev/null 2>&1; then
        mysql -N -e "SHOW VARIABLES WHERE Variable_name IN ('slow_query_log','long_query_time','slow_query_log_file')" 2>/dev/null || echo "Run as a user with local mysql admin access to see server variables."
    else
        echo "mysql client not installed"
    fi
}

case "${1:-status}" in
    status)
        show_status
        ;;
    -h | --help)
        echo "Usage: releasepanel mysql status"
        ;;
    *)
        echo "[error] Unknown subcommand: ${1:-}" >&2
        exit 1
        ;;
esac
