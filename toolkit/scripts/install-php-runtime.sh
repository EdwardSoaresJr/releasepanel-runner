#!/usr/bin/env bash
set -Eeuo pipefail

PHP_VERSION="${1:-}"
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

fail() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

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
    apt-get \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        update -y
}

apt_package_available() {
    local package="$1"

    apt-cache show "${package}" >/dev/null 2>&1
}

install_ondrej_php_repo() {
    local keyring="/etc/apt/keyrings/ondrej-php.gpg"
    local source_list="/etc/apt/sources.list.d/ondrej-php.list"
    local key_id="14AA40EC0831756756D7F66C4F4EA0AAE5267A6C"
    local ppa_url="${RELEASEPANEL_PHP_PPA_URL:-http://ppa.launchpad.net/ondrej/php/ubuntu}"
    local codename

    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"

    [ -n "${codename}" ] || fail "Unable to detect Ubuntu codename from /etc/os-release"

    install -d -m 0755 /etc/apt/keyrings

    if [ ! -f "${keyring}" ]; then
        gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "${key_id}"
        gpg --batch --export "${key_id}" > "${keyring}"
        chmod 644 "${keyring}"
    fi

    cat > "${source_list}" <<EOF
deb [signed-by=${keyring}] ${ppa_url} ${codename} main
EOF
}

configure_php_fpm_pool() {
    local pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

    [ -f "${pool_conf}" ] || fail "PHP-FPM pool config missing at ${pool_conf}"

    sed -i -E \
        -e 's#^[;[:space:]]*user[[:space:]]*=.*#user = www-data#' \
        -e 's#^[;[:space:]]*group[[:space:]]*=.*#group = www-data#' \
        -e "s#^[;[:space:]]*listen[[:space:]]*=.*#listen = ${PHP_SOCK}#" \
        -e 's#^[;[:space:]]*listen\.owner[[:space:]]*=.*#listen.owner = www-data#' \
        -e 's#^[;[:space:]]*listen\.group[[:space:]]*=.*#listen.group = www-data#' \
        -e 's#^[;[:space:]]*listen\.mode[[:space:]]*=.*#listen.mode = 0660#' \
        "${pool_conf}"
}

if [ "$(id -u)" -ne 0 ]; then
    fail "Run this script as root."
fi

if ! printf '%s' "${PHP_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+$'; then
    fail "Usage: ${0##*/} <php-version>  # example: ${0##*/} 8.4"
fi

apt_update_noninteractive
apt_get_noninteractive install -y apt-transport-https ca-certificates curl dirmngr gnupg

if ! apt_package_available "php${PHP_VERSION}"; then
    echo "[releasepanel] PHP ${PHP_VERSION} is not available from current apt sources; adding Ondrej PHP repository."
    install_ondrej_php_repo
    apt_update_noninteractive
fi

apt_package_available "php${PHP_VERSION}" || fail "php${PHP_VERSION} is not available from apt after repository setup."

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

configure_php_fpm_pool

systemctl enable "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"

[ -S "${PHP_SOCK}" ] || fail "PHP-FPM socket missing at ${PHP_SOCK}"

echo "[releasepanel] PHP ${PHP_VERSION} runtime ready at ${PHP_SOCK}."
