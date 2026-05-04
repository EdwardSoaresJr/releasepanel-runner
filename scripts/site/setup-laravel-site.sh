#!/usr/bin/env bash
# Managed Laravel site runtime: PHP-FPM pool, nginx vhost, optional queue workers.
# Source of truth lives in releasepanel-runner; ReleasePanel dispatches this script only.
set -euo pipefail

log() {
  printf '%s\n' "[site] $*"
}

die() {
  printf '%s\n' "[site] ERROR: $*" >&2
  exit 1
}

require_env() {
  local n="$1"
  local v="${!n:-}"
  if [ -z "$v" ]; then
    die "missing required environment variable: $n"
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  die "must run as root"
fi

if [ ! -f /etc/os-release ]; then
  die "/etc/os-release not found (Ubuntu required)"
fi
# shellcheck source=/dev/null
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  die "Ubuntu required (ID=${ID:-unknown})"
fi

require_env RELEASEPANEL_SITE_SLUG
require_env RELEASEPANEL_SITE_DOMAIN
require_env RELEASEPANEL_SITE_ROOT

SLUG="${RELEASEPANEL_SITE_SLUG}"
DOMAIN="${RELEASEPANEL_SITE_DOMAIN}"
SITE_ROOT="${RELEASEPANEL_SITE_ROOT}"

if ! [[ "$SLUG" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  die "RELEASEPANEL_SITE_SLUG must match [a-z0-9-] (safe slug)"
fi

if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  die "RELEASEPANEL_SITE_DOMAIN must match hostname-safe characters [a-z0-9.-]"
fi

case "$SITE_ROOT" in
  /var/www/*) ;;
  *) die "RELEASEPANEL_SITE_ROOT must be under /var/www" ;;
esac

PHP_VERSION="${RELEASEPANEL_PHP_VERSION:-8.3}"
if ! [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
  die "RELEASEPANEL_PHP_VERSION must look like 8.3"
fi

ENABLE_QUEUE_RAW="${RELEASEPANEL_ENABLE_QUEUE:-false}"
ENABLE_QUEUE=false
case "$ENABLE_QUEUE_RAW" in
  1|true|TRUE|yes|YES) ENABLE_QUEUE=true ;;
  0|false|FALSE|no|NO) ENABLE_QUEUE=false ;;
  *) die "RELEASEPANEL_ENABLE_QUEUE must be true or false" ;;
esac

QUEUE_CONNECTION="${RELEASEPANEL_QUEUE_CONNECTION:-database}"
if ! [[ "$QUEUE_CONNECTION" =~ ^(database|redis|sync)$ ]]; then
  die "RELEASEPANEL_QUEUE_CONNECTION must be database, redis, or sync"
fi

QUEUE_NAME="${RELEASEPANEL_QUEUE_NAME:-default}"
if ! [[ "$QUEUE_NAME" =~ ^[A-Za-z0-9,_-]+$ ]]; then
  die "RELEASEPANEL_QUEUE_NAME must contain only letters, numbers, comma, dash, underscore"
fi

QUEUE_WORKERS="${RELEASEPANEL_QUEUE_WORKERS:-1}"
if ! [[ "$QUEUE_WORKERS" =~ ^[0-9]+$ ]] || [ "$QUEUE_WORKERS" -lt 1 ] || [ "$QUEUE_WORKERS" -gt 4 ]; then
  die "RELEASEPANEL_QUEUE_WORKERS must be an integer 1-4"
fi

PHP_ETC="/etc/php/${PHP_VERSION}"
FPM_POOL_DIR="${PHP_ETC}/fpm/pool.d"
POOL_FILE="${FPM_POOL_DIR}/${SLUG}.conf"
POOL_NAME="releasepanel-${SLUG}"
SOCKET_PATH="/run/php/php${PHP_VERSION}-fpm-${SLUG}.sock"
NGINX_AVAIL="/etc/nginx/sites-available/${SLUG}"
NGINX_EN="/etc/nginx/sites-enabled/${SLUG}"
SUP_CONF="/etc/supervisor/conf.d/${SLUG}-queue.conf"

log "Setting up Laravel site: ${DOMAIN}"

if [ ! -d "${PHP_ETC}/fpm" ]; then
  die "PHP-FPM for ${PHP_VERSION} not installed (missing ${PHP_ETC}/fpm)"
fi

mkdir -p "$FPM_POOL_DIR"

mkdir -p "$SITE_ROOT"
if id deploy >/dev/null 2>&1; then
  chown -R deploy:deploy "$SITE_ROOT"
else
  chown -R www-data:www-data "$SITE_ROOT"
fi

log "PHP-FPM pool: ${POOL_NAME} → ${POOL_FILE}"
cat >"$POOL_FILE" <<POOL_EOF
[${POOL_NAME}]
user = www-data
group = www-data
listen = ${SOCKET_PATH}
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 8
pm.start_servers = 2
pm.min_spare_servers = 2
pm.max_spare_servers = 4
clear_env = no
POOL_EOF

log "Nginx config: ${NGINX_AVAIL}"
if [ -f "$NGINX_AVAIL" ] || [ -L "$NGINX_AVAIL" ]; then
  log "Nginx site config already exists; not overwriting"
else
  cat >"$NGINX_AVAIL" <<NGINX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${SITE_ROOT}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCKET_PATH};
    }

    location ~ /\\.ht {
        deny all;
    }
}
NGINX_EOF
fi

ln -sfn "$NGINX_AVAIL" "$NGINX_EN"

if [ "$ENABLE_QUEUE" = true ]; then
  log "Queue: enabled (${QUEUE_CONNECTION}, workers=${QUEUE_WORKERS}, name=${QUEUE_NAME})"
  if ! command -v supervisorctl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s supervisor >/dev/null 2>&1; then
      if [ ! -d /var/lib/apt/lists ] || [ -z "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]; then
        log "Refreshing apt lists (supervisor install)"
        _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/apt-optimizations.sh"
        if [ -f "${_lib}" ]; then
          # shellcheck source=/dev/null
          . "${_lib}"
          command -v force_ipv4_apt >/dev/null 2>&1 && force_ipv4_apt || true
          command -v configure_apt_timeouts >/dev/null 2>&1 && configure_apt_timeouts || true
          command -v apply_detected_mirror >/dev/null 2>&1 && apply_detected_mirror || true
          command -v clean_apt_cache_safe >/dev/null 2>&1 && clean_apt_cache_safe || true
          command -v apt_update_safe >/dev/null 2>&1 && apt_update_safe || true
        else
          apt-get update -y || true
        fi
      fi
      apt-get install -y --no-install-recommends supervisor
    fi
  fi

  cat >"$SUP_CONF" <<SUP_EOF
[program:${SLUG}-queue]
process_name=%(program_name)s_%(process_num)02d
command=php ${SITE_ROOT}/artisan queue:work ${QUEUE_CONNECTION} --queue=${QUEUE_NAME} --sleep=1 --tries=3 --timeout=120
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=${QUEUE_WORKERS}
redirect_stderr=true
stdout_logfile=/var/log/${SLUG}-queue.log
stopwaitsecs=3600
SUP_EOF

  supervisorctl reread
  supervisorctl update
  if supervisorctl status "${SLUG}-queue:"* >/dev/null 2>&1; then
    supervisorctl restart "${SLUG}-queue:"* || true
  else
    supervisorctl start "${SLUG}-queue:"* || true
  fi
  systemctl enable --now supervisor 2>/dev/null || true
else
  log "Queue: disabled (supervisor config unchanged if present)"
fi

systemctl restart "php${PHP_VERSION}-fpm"
nginx -t
systemctl reload nginx

log "Complete."
