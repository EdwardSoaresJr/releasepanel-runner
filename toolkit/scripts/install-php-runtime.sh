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

strip_ondrej_launchpad_sources() {
    local f
    shopt -s nullglob
    for f in \
        /etc/apt/sources.list.d/*ondrej* \
        /etc/apt/sources.list.d/*launchpadcontent_net_ondrej* \
        /etc/apt/sources.list.d/*ppa.launchpadcontent.net_ondrej*; do
        echo "[releasepanel] Removing stale apt source (Ondřej / Launchpad): ${f}"
        rm -f "${f}"
    done
    shopt -u nullglob
}

ensure_php_in_apt_ubuntu() {
    local pkg="php${PHP_VERSION}"
    if apt_package_available "${pkg}"; then
        return 0
    fi
    echo "[releasepanel] ${pkg} not in apt indexes — enabling universe (native packages on Ubuntu noble+) ..."
    apt_get_noninteractive install -y software-properties-common
    add-apt-repository universe -y 2>/dev/null || true
    apt_update_noninteractive
    apt_package_available "${pkg}"
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
    fail "Usage: ${0##*/} <php-version>  # example: ${0##*/} 8.3"
fi

# shellcheck disable=SC1091
. /etc/os-release
UBUNTU_CODENAME="${VERSION_CODENAME:-}"
if [ "${ID:-}" != "ubuntu" ] || [[ ! "${UBUNTU_CODENAME}" =~ ^(noble|oracular|questing)$ ]]; then
    fail "This installer targets Ubuntu 24.04 LTS (noble) and newer Ubuntu LTS with distro PHP only. Found: ${ID:-?} ${UBUNTU_CODENAME:-?}. Use a noble image (no Ondřej PPA)."
fi

strip_ondrej_launchpad_sources || true

apt_update_noninteractive
apt_get_noninteractive install -y apt-transport-https ca-certificates curl dirmngr gnupg

if ! ensure_php_in_apt_ubuntu; then
    fail "php${PHP_VERSION} is not available from Ubuntu archives. On noble, enable universe and use distro packages only (PHP 8.3 is default)."
fi

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
