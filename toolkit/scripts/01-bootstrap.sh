#!/usr/bin/env bash
set -Eeuo pipefail

echo "[bootstrap] Starting system bootstrap..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
. /etc/os-release || true
UBUNTU_CODENAME="${VERSION_CODENAME:-}"
if [ "${ID:-}" != "ubuntu" ] || [[ ! "${UBUNTU_CODENAME}" =~ ^(noble|oracular|questing)$ ]]; then
    echo "[bootstrap] This script targets Ubuntu 24.04 LTS (noble) with native PHP packages only."
    echo "[bootstrap] Found: ID=${ID:-unknown} VERSION_CODENAME=${UBUNTU_CODENAME:-unknown} — use a noble (or newer supported Ubuntu) image."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

apt_get_noninteractive() {
    apt-get \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

apt_update_noninteractive() {
    if apt-get \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        update -y; then
        return 0
    fi

    echo "[bootstrap] apt update failed; retrying with IPv4."
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

    apt-get \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        update -y
}

require_apt_package_available() {
    local package="$1"

    if apt-cache show "${package}" >/dev/null 2>&1; then
        return 0
    fi

    echo "[bootstrap] ERROR: ${package} is not available from apt."
    echo "[bootstrap] On Ubuntu noble, enable universe (sudo add-apt-repository universe) and run apt-get update."
    exit 1
}

apt_package_available() {
    local package="$1"

    apt-cache show "${package}" >/dev/null 2>&1
}

strip_ondrej_launchpad_sources() {
    local f
    shopt -s nullglob
    for f in \
        /etc/apt/sources.list.d/*ondrej* \
        /etc/apt/sources.list.d/*launchpadcontent_net_ondrej* \
        /etc/apt/sources.list.d/*ppa.launchpadcontent.net_ondrej*; do
        echo "[bootstrap] Removing stale apt source (Ondřej / Launchpad): ${f}"
        rm -f "${f}"
    done
    shopt -u nullglob
}

ensure_php_available_native() {
    if apt_package_available "php${PHP_VERSION}"; then
        return 0
    fi
    echo "[bootstrap] php${PHP_VERSION} not in apt indexes — enabling universe (minimal cloud images) ..."
    apt_get_noninteractive install -y software-properties-common
    add-apt-repository universe -y 2>/dev/null || true
    apt_update_noninteractive || true
    apt_package_available "php${PHP_VERSION}"
}

PHP_VERSION="${PHP_VERSION:-${RELEASEPANEL_PHP_VERSION:-8.3}}"
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

strip_ondrej_launchpad_sources || true

apt_update_noninteractive
apt_get_noninteractive upgrade -y

apt_get_noninteractive install -y \
    apt-transport-https \
    ca-certificates \
    certbot \
    curl \
    dirmngr \
    fzf \
    git \
    gnupg \
    nginx \
    python3-certbot-nginx \
    redis-server \
    software-properties-common \
    supervisor \
    unzip \
    zip

if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q '^v20\.'; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt_get_noninteractive install -y nodejs
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "[bootstrap] npm missing after Node install; installing npm."
    apt_get_noninteractive install -y npm
fi

if ! apt_package_available "php${PHP_VERSION}" && [ "${PHP_VERSION}" != "8.3" ]; then
    echo "[bootstrap] php${PHP_VERSION} unavailable; falling back to 8.3."
    PHP_VERSION="8.3"
    PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
fi

if ensure_php_available_native; then
    echo "[bootstrap] PHP ${PHP_VERSION} is available from apt."
else
    echo "[bootstrap] php${PHP_VERSION} still not available after enabling universe — use Ubuntu noble with native PHP 8.3."
    exit 1
fi
require_apt_package_available "php${PHP_VERSION}"

apt_get_noninteractive install -y \
    "php${PHP_VERSION}" \
    "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-intl" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-redis" \
    "php${PHP_VERSION}-sqlite3" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-zip"

pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
if [ ! -f "${pool_conf}" ]; then
    echo "[bootstrap] ERROR: PHP-FPM pool config missing at ${pool_conf}"
    exit 1
fi

sed -i -E \
    -e 's#^[;[:space:]]*user[[:space:]]*=.*#user = www-data#' \
    -e 's#^[;[:space:]]*group[[:space:]]*=.*#group = www-data#' \
    -e "s#^[;[:space:]]*listen[[:space:]]*=.*#listen = ${PHP_SOCK}#" \
    -e 's#^[;[:space:]]*listen\.owner[[:space:]]*=.*#listen.owner = www-data#' \
    -e 's#^[;[:space:]]*listen\.group[[:space:]]*=.*#listen.group = www-data#' \
    -e 's#^[;[:space:]]*listen\.mode[[:space:]]*=.*#listen.mode = 0660#' \
    "${pool_conf}"

if ! command -v composer >/dev/null 2>&1; then
    apt_get_noninteractive install -y composer
fi

systemctl enable nginx
systemctl enable "php${PHP_VERSION}-fpm"
systemctl enable redis-server
systemctl enable supervisor

systemctl start nginx
systemctl restart "php${PHP_VERSION}-fpm"
systemctl start redis-server
systemctl start supervisor

if [ ! -S "${PHP_SOCK}" ]; then
    echo "[bootstrap] ERROR: PHP-FPM socket missing at ${PHP_SOCK}"
    exit 1
fi

mkdir -p /var/www/sites
mkdir -p "${TOOLKIT_DIR}/sites"
ln -sf "${TOOLKIT_DIR}/bin/managed-deploy" /usr/local/bin/managed-deploy
if [ "${RELEASEPANEL_SKIP_APP_BOOTSTRAP:-false}" != "true" ]; then
    ln -sf "${TOOLKIT_DIR}/bin/releasepanel" /usr/local/bin/releasepanel
fi

chown -R www-data:www-data /var/www
chmod -R 755 /var/www

rm -f /etc/nginx/sites-enabled/default || true

for service in nginx "php${PHP_VERSION}-fpm" redis-server supervisor; do
    systemctl is-active --quiet "${service}" || {
        echo "[bootstrap] ERROR: ${service} is not active"
        exit 1
    }
done

nginx -t
systemctl reload nginx

echo "[bootstrap] System bootstrap complete."

if [ "${RELEASEPANEL_SKIP_APP_BOOTSTRAP:-false}" = "true" ]; then
    echo "[bootstrap] Skipping control-plane app install (RELEASEPANEL_SKIP_APP_BOOTSTRAP=true). Managed-agent host only — no hosted panel deployed here."
    install -d -m 0755 /var/lib/managed-deploy-agent
    touch /var/lib/managed-deploy-agent/bootstrap-runner.completed
    echo "[bootstrap] COMPLETE"
    exit 0
fi

if [ -f "${SCRIPT_DIR}/bootstrap-releasepanel.sh" ]; then
    echo "[bootstrap] Starting control-plane bootstrap (hosted panel)..."
    bash "${SCRIPT_DIR}/bootstrap-releasepanel.sh"
else
    echo "[bootstrap] ERROR: Missing bootstrap-releasepanel.sh (managed-server toolkit has no control-plane bootstrap; use: sudo releasepanel bootstrap-runner)"
    exit 1
fi

echo "[bootstrap] COMPLETE"
