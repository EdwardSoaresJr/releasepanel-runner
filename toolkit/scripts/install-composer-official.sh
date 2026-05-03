#!/usr/bin/env bash
#
# One-shot: install Composer from getcomposer.org to /usr/local/bin/composer.
# Use after `apt-get remove composer` when /usr/local/bin/composer was never created.
# Root only. Does not require a site environment config.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root

# Provisioning runs as root; Composer otherwise prompts interactively.
export COMPOSER_ALLOW_SUPERUSER=1

if [ -x /usr/local/bin/composer ]; then
    log "Composer already installed:"
    /usr/local/bin/composer --version --no-ansi
    exit 0
fi

log "Installing Composer (official) to /usr/local/bin/composer"
EXPECTED_SIGNATURE="$(curl -fsS https://composer.github.io/installer.sig)"
php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
[ "${EXPECTED_SIGNATURE}" = "${ACTUAL_SIGNATURE}" ] || fail "Composer installer signature mismatch."
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
rm -f /tmp/composer-setup.php
chmod 755 /usr/local/bin/composer
/usr/local/bin/composer --version --no-ansi
log "Done. Deploy uses /usr/local/bin/composer when this file exists."
