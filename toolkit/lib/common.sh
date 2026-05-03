#!/usr/bin/env bash

set -Eeuo pipefail

__releasepanel_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__releasepanel_default_toolkit="$(cd "${__releasepanel_common_dir}/.." && pwd)"
RELEASEPANEL_TOOLKIT_DIR="${RELEASEPANEL_TOOLKIT_DIR:-${__releasepanel_default_toolkit}}"
unset __releasepanel_common_dir __releasepanel_default_toolkit
RELEASEPANEL_DEPLOY_ENV="${RELEASEPANEL_DEPLOY_ENV:-${RELEASEPANEL_TOOLKIT_DIR}/deploy.env}"

log() {
    printf '\033[1;34m[releasepanel]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[warning]\033[0m %s\n' "$*" >&2
}

fail() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Run this script as root."
    fi
}

normalize_site_env() {
    local input="$1"

    if [[ "${input}" =~ ^([A-Za-z0-9_-]+)[[:space:]]+([A-Za-z0-9_-]+)$ ]]; then
        printf '%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    printf '%s\n' "${input}"
}

resolve_site_env_config() {
    local site_env
    local env_file
    local site
    local env

    site_env="$(normalize_site_env "$1")"

    if ! printf '%s' "${site_env}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        return 1
    fi

    for env_file in "${RELEASEPANEL_TOOLKIT_DIR}/sites/"*/*.env; do
        [ -e "${env_file}" ] || continue

        env="$(basename "${env_file}" .env)"
        site="$(basename "$(dirname "${env_file}")")"

        if [ "${site}-${env}" = "${site_env}" ]; then
            SITE_SLUG="${site}"
            ENV_SLUG="${env}"
            SITE_ENV_NAME="${site_env}"
            RELEASEPANEL_DEPLOY_ENV="${env_file}"
            export SITE_SLUG ENV_SLUG SITE_ENV_NAME RELEASEPANEL_DEPLOY_ENV
            return 0
        fi
    done

    return 1
}

parse_deploy_env_as_first_arg() {
    local env_name="$1"

    if resolve_site_env_config "${env_name}"; then
        return 0
    fi

    return 1
}

load_env() {
    if [ ! -f "${RELEASEPANEL_DEPLOY_ENV}" ]; then
        if [ ! -f "${RELEASEPANEL_TOOLKIT_DIR}/.env.example" ]; then
            fail "Missing ${RELEASEPANEL_DEPLOY_ENV} and ${RELEASEPANEL_TOOLKIT_DIR}/.env.example."
        fi

        echo "[releasepanel] Step: Creating deploy.env from .env.example"
        cp "${RELEASEPANEL_TOOLKIT_DIR}/.env.example" "${RELEASEPANEL_DEPLOY_ENV}"
        chmod 600 "${RELEASEPANEL_DEPLOY_ENV}"
        warn "Created ${RELEASEPANEL_DEPLOY_ENV}. Review it before SSL/certbot or production deploy steps."
    fi

    set -a
    # shellcheck disable=SC1090
    . "${RELEASEPANEL_DEPLOY_ENV}"
    set +a

    : "${SITE_SLUG:=${RELEASEPANEL_SITE_SLUG:-site}}"
    : "${ENV_SLUG:=${RELEASEPANEL_ENV_SLUG:-env}}"
    : "${REPO_URL:=${RELEASEPANEL_REPO:-}}"
    : "${BRANCH:=${RELEASEPANEL_BRANCH:-master}}"
    : "${DOMAIN:=${RELEASEPANEL_SERVER_NAME:-}}"
    : "${BASE_PATH:=${RELEASEPANEL_BASE:-/var/www/sites/${SITE_SLUG}/${ENV_SLUG}}}"
    : "${PHP_VERSION:=${RELEASEPANEL_PHP_VERSION:-8.3}}"
    : "${HEALTH_PATH:=${RELEASEPANEL_HEALTH_PATH:-/up}}"
    : "${WORKER_MODE:=${RELEASEPANEL_WORKER_MODE:-queue}}"
    : "${RELEASEPANEL_APP_USER:=releasepanel}"
    : "${APP_USER:=${RELEASEPANEL_APP_USER}}"
    : "${FILE_GROUP:=${RELEASEPANEL_FILE_GROUP:-www-data}}"

    RELEASEPANEL_SITE_SLUG="${SITE_SLUG}"
    RELEASEPANEL_ENV_SLUG="${ENV_SLUG}"
    RELEASEPANEL_REPO="${REPO_URL}"
    RELEASEPANEL_BRANCH="${BRANCH}"
    RELEASEPANEL_SERVER_NAME="${DOMAIN}"
    RELEASEPANEL_BASE="${BASE_PATH}"
    RELEASEPANEL_PHP_VERSION="${PHP_VERSION}"
    RELEASEPANEL_HEALTH_PATH="${HEALTH_PATH}"
    RELEASEPANEL_WORKER_MODE="${WORKER_MODE}"
    RELEASEPANEL_APP_USER="${APP_USER}"
    RELEASEPANEL_FILE_GROUP="${FILE_GROUP}"

    : "${RELEASEPANEL_APP_SUBDIR:=}"
    : "${RELEASEPANEL_ENV:=${SITE_SLUG}-${ENV_SLUG}}"
    : "${RELEASEPANEL_SERVER_ALIASES:=}"
    : "${RELEASEPANEL_CERTBOT_EXTRA_DOMAINS:=}"
    : "${RELEASEPANEL_ENABLE_TENANT_MIGRATIONS:=false}"
    : "${RELEASEPANEL_RUN_NPM:=true}"
    : "${RELEASEPANEL_SKIP_ASSET_BUILD:=false}"
    : "${RELEASEPANEL_SSL_EMAIL:=}"
    : "${RELEASEPANEL_PUBLIC_URL:=}"
    : "${RELEASEPANEL_OPS_HEALTH_BASE_URL:=}"
    : "${RELEASEPANEL_SSH_IDENTITY_FILE:=}"
    : "${RELEASEPANEL_GIT_SSH_COMMAND:=}"
    : "${OPS_INTERNAL_HEALTH_SECRET:=}"

    if ! printf '%s' "${RELEASEPANEL_PHP_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+$'; then
        fail "RELEASEPANEL_PHP_VERSION must be a version like 8.3 or 8.4, got: ${RELEASEPANEL_PHP_VERSION}"
    fi

    RELEASEPANEL_RELEASES="${RELEASEPANEL_BASE}/releases"
    RELEASEPANEL_SHARED="${RELEASEPANEL_BASE}/shared"
    RELEASEPANEL_CURRENT="${RELEASEPANEL_BASE}/current"
    RELEASEPANEL_DEPLOY_LOCK="/var/lock/releasepanel-${RELEASEPANEL_ENV}-deploy.lock"
    RELEASEPANEL_PROGRAM_PREFIX="releasepanel-${RELEASEPANEL_ENV}"
    RELEASEPANEL_NGINX_SITE_BASENAME="${RELEASEPANEL_NGINX_SITE_BASENAME:-${RELEASEPANEL_ENV}}"

    if [ -z "${RELEASEPANEL_GIT_SSH_COMMAND}" ] && [ -n "${RELEASEPANEL_SSH_IDENTITY_FILE}" ]; then
        RELEASEPANEL_GIT_SSH_COMMAND="ssh -i ${RELEASEPANEL_SSH_IDENTITY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    fi

    validate_domain_strategy
    log "Environment: ${RELEASEPANEL_ENV}"
    echo "Domain: ${RELEASEPANEL_SERVER_NAME}"
}

require_env_value() {
    local name="$1"
    local value="${!name:-}"

    if [ -z "${value}" ]; then
        fail "${name} must be set in deploy.env."
    fi
}

lock_holders() {
    local lock_file="$1"

    if command -v fuser >/dev/null 2>&1; then
        fuser "${lock_file}" 2>/dev/null | tr ' ' '\n' | awk 'NF' | sort -u

        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -t "${lock_file}" 2>/dev/null | sort -u
    fi
}

process_state() {
    local pid="$1"

    if [ -r "/proc/${pid}/stat" ]; then
        awk '{print $3}' "/proc/${pid}/stat"

        return 0
    fi

    ps -o state= -p "${pid}" 2>/dev/null | awk '{print $1}'
}

recover_stopped_lock_holders() {
    local lock_file="$1"
    local recovered=false
    local pid
    local state

    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue

        state="$(process_state "${pid}" || true)"
        case "${state}" in
            T | t)
                warn "Deploy lock is held by stopped process ${pid}; terminating it so deploy can continue."
                kill "${pid}" 2>/dev/null || true
                sleep 1
                if kill -0 "${pid}" 2>/dev/null; then
                    warn "Stopped process ${pid} did not exit; forcing termination."
                    kill -9 "${pid}" 2>/dev/null || true
                fi
                recovered=true
                ;;
        esac
    done < <(lock_holders "${lock_file}")

    [ "${recovered}" = "true" ]
}

describe_lock_holders() {
    local lock_file="$1"
    local holders

    holders="$(lock_holders "${lock_file}" | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    if [ -n "${holders}" ]; then
        printf 'Lock holders: %s' "${holders}"
    else
        printf 'No lock holders detected.'
    fi
}

acquire_deploy_lock() {
    exec 9>"${RELEASEPANEL_DEPLOY_LOCK}"

    if flock -n 9; then
        return 0
    fi

    recover_stopped_lock_holders "${RELEASEPANEL_DEPLOY_LOCK}" || true

    if flock -n 9; then
        return 0
    fi

    fail "Another deploy is already running. $(describe_lock_holders "${RELEASEPANEL_DEPLOY_LOCK}")"
}

validate_domain_strategy() {
    local alias

    if [ -z "${RELEASEPANEL_SERVER_NAME}" ]; then
        fail "RELEASEPANEL_SERVER_NAME must be set in site environment config."
    fi

    if [[ "${RELEASEPANEL_SERVER_NAME}" == *"*"* ]]; then
        fail "RELEASEPANEL_SERVER_NAME must be an exact domain, not a wildcard."
    fi

    for alias in ${RELEASEPANEL_SERVER_ALIASES}; do
        if [[ "${alias}" == *"*"* && "${alias}" != \*.* ]]; then
            fail "Wildcard alias ${alias} must be in the form *.example.com."
        fi
    done
}

nginx_server_names() {
    printf '%s' "${RELEASEPANEL_SERVER_NAME}"

    if [ -n "${RELEASEPANEL_SERVER_ALIASES}" ]; then
        printf ' %s' ${RELEASEPANEL_SERVER_ALIASES}
    fi
}

validate_nginx_domain_file() {
    local file="$1"
    local domain_regex="${RELEASEPANEL_SERVER_NAME//./\\.}"

    if ! grep -Eq "^[[:space:]]*server_name[[:space:]].*\\b${domain_regex}\\b.*;[[:space:]]*$" "${file}"; then
        fail "nginx config ${file} must include ${RELEASEPANEL_SERVER_NAME}."
    fi
}

run_as_app_user() {
    if [ -n "${RELEASEPANEL_GIT_SSH_COMMAND:-}" ]; then
        sudo -Hu "${RELEASEPANEL_APP_USER}" env "GIT_SSH_COMMAND=${RELEASEPANEL_GIT_SSH_COMMAND}" "$@"

        return
    fi

    sudo -Hu "${RELEASEPANEL_APP_USER}" "$@"
}

run_as_app_user_in() {
    local dir="$1"
    shift

    if [ -n "${RELEASEPANEL_GIT_SSH_COMMAND:-}" ]; then
        sudo -Hu "${RELEASEPANEL_APP_USER}" env "GIT_SSH_COMMAND=${RELEASEPANEL_GIT_SSH_COMMAND}" bash -lc "cd $(printf '%q' "${dir}") && $(printf '%q ' "$@")"

        return
    fi

    sudo -Hu "${RELEASEPANEL_APP_USER}" bash -lc "cd $(printf '%q' "${dir}") && $(printf '%q ' "$@")"
}

promote_app_subdir_release() {
    local release="${RELEASE_PATH:?RELEASE_PATH must be set before promote_app_subdir_release}"
    local subdir="${RELEASEPANEL_APP_SUBDIR:-}"
    local app_path
    local tmp_path

    if [ -z "${subdir}" ]; then
        return 0
    fi

    case "${subdir}" in
        /*|*..*|*~*)
            fail "RELEASEPANEL_APP_SUBDIR must be a safe relative path."
            ;;
    esac

    app_path="${release}/${subdir}"
    tmp_path="${release}.app"

    if [ ! -d "${app_path}" ]; then
        fail "RELEASEPANEL_APP_SUBDIR=${subdir} not found in release."
    fi
    if [ ! -f "${app_path}/composer.json" ] || [ ! -f "${app_path}/public/index.php" ]; then
        fail "RELEASEPANEL_APP_SUBDIR=${subdir} is not a Laravel app root."
    fi

    log "Using app subdirectory ${subdir} as release root."
    rm -rf "${tmp_path}"
    mv "${app_path}" "${tmp_path}"
    rm -rf "${release}"
    mv "${tmp_path}" "${release}"
    chown -R "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${release}"
}

ensure_app_layout() {
    mkdir -p "${RELEASEPANEL_RELEASES}" "${RELEASEPANEL_SHARED}"
    case "${RELEASEPANEL_FULL_TREE_PERMISSIONS:-}" in
        1 | true | TRUE | yes | YES)
            chown -R "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_BASE}"
            ;;
        *)
            chown "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_BASE}" "${RELEASEPANEL_RELEASES}" "${RELEASEPANEL_SHARED}"
            ;;
    esac
    chmod 2775 "${RELEASEPANEL_BASE}" "${RELEASEPANEL_RELEASES}" "${RELEASEPANEL_SHARED}"
}

ensure_shared_filesystem() {
    mkdir -p \
        "${RELEASEPANEL_SHARED}/storage/framework/cache" \
        "${RELEASEPANEL_SHARED}/storage/framework/cache/data" \
        "${RELEASEPANEL_SHARED}/storage/framework/sessions" \
        "${RELEASEPANEL_SHARED}/storage/framework/views" \
        "${RELEASEPANEL_SHARED}/storage/logs" \
        "${RELEASEPANEL_SHARED}/bootstrap/cache"

    if [ ! -f "${RELEASEPANEL_SHARED}/.env" ]; then
        touch "${RELEASEPANEL_SHARED}/.env"
    fi

    if [ ! -s "${RELEASEPANEL_SHARED}/.env" ]; then
        local stub_app_key=""
        if command -v php >/dev/null 2>&1; then
            stub_app_key="$(php -r "echo 'base64:'.base64_encode(random_bytes(32));")"
        fi
        if [ -z "${stub_app_key}" ]; then
            warn 'php not found; starter shared/.env has empty APP_KEY — set APP_KEY before encrypting data.'
        fi
        cat > "${RELEASEPANEL_SHARED}/.env" <<EOF
APP_NAME=Laravel App
APP_ENV=production
APP_DEBUG=true
APP_URL=${RELEASEPANEL_PUBLIC_URL:-https://${RELEASEPANEL_SERVER_NAME}}
APP_KEY=${stub_app_key}
APP_TIMEZONE=UTC
LOG_CHANNEL=stack
CACHE_DRIVER=file
SESSION_DRIVER=file
QUEUE_CONNECTION=sync
EOF
    fi

    chown -R "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${RELEASEPANEL_SHARED}"
    chmod 660 "${RELEASEPANEL_SHARED}/.env"
    chmod -R 775 "${RELEASEPANEL_SHARED}/storage" "${RELEASEPANEL_SHARED}/bootstrap/cache"
}

link_shared_paths() {
    local release="${RELEASE_PATH:?RELEASE_PATH must be set before link_shared_paths}"

    echo "[releasepanel] Step: Linking storage + env"
    ensure_shared_filesystem

    rm -rf "${release}/storage"
    ln -sfn "${RELEASEPANEL_SHARED}/storage" "${release}/storage"

    rm -f "${release}/.env"
    ln -sfn "${RELEASEPANEL_SHARED}/.env" "${release}/.env"

    chown -h "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${release}/storage" "${release}/.env"
}

prepare_release_filesystem() {
    local release="${RELEASE_PATH:?RELEASE_PATH must be set before prepare_release_filesystem}"

    echo "[releasepanel] Step: Preparing filesystem"
    echo "[debug] RELEASE_PATH=${release}"

    mkdir -p \
        "${release}/bootstrap/cache" \
        "${release}/storage/framework/cache" \
        "${release}/storage/framework/cache/data" \
        "${release}/storage/framework/sessions" \
        "${release}/storage/framework/views" \
        "${release}/storage/logs" \
        "${RELEASEPANEL_SHARED}/bootstrap/cache"

    chown -R "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${release}" "${RELEASEPANEL_SHARED}/bootstrap/cache"
    chmod -R 775 "${release}/bootstrap/cache" "${release}/storage" "${RELEASEPANEL_SHARED}/bootstrap/cache"
}

validate_release_ready() {
    local release="${RELEASE_PATH:?RELEASE_PATH must be set before validate_release_ready}"

    if [ ! -f "${release}/vendor/autoload.php" ]; then
        echo "[error] vendor missing"
        exit 1
    fi

    if [ ! -f "${release}/public/index.php" ]; then
        echo "[error] public/index.php missing"
        exit 1
    fi

    if [ ! -L "${release}/.env" ]; then
        echo "[error] release .env symlink missing"
        exit 1
    fi

    if [ "$(readlink "${release}/.env")" != "${RELEASEPANEL_SHARED}/.env" ]; then
        echo "[error] release .env symlink does not point to shared .env"
        exit 1
    fi

    if [ ! -L "${release}/storage" ]; then
        echo "[error] release storage symlink missing"
        exit 1
    fi

    if [ "$(readlink "${release}/storage")" != "${RELEASEPANEL_SHARED}/storage" ]; then
        echo "[error] release storage symlink does not point to shared storage"
        exit 1
    fi
}

validate_shared_env_for_artisan() {
    local env_file="${RELEASEPANEL_SHARED}/.env"

    if [ ! -f "${env_file}" ]; then
        echo "[error] Missing shared .env"
        exit 1
    fi

    if ! grep -q '^APP_KEY=.' "${env_file}"; then
        echo "[error] APP_KEY missing"
        exit 1
    fi

    if ! grep -q '^APP_URL=.' "${env_file}"; then
        echo "[error] APP_URL missing"
        exit 1
    fi

    if [ "${RELEASEPANEL_SITE_SLUG}" != "releasepanel-app" ] && grep -q '^DB_CONNECTION=central$' "${env_file}"; then
        echo "[error] ${RELEASEPANEL_ENV} shared .env has DB_CONNECTION=central, but this ReleasePanel app defines mysql as its central/landlord connection."
        echo "[error] Set DB_CONNECTION=mysql in ${env_file}, then clear Laravel config cache and redeploy."
        exit 1
    fi
}

require_composer() {
    if ! command -v composer >/dev/null 2>&1; then
        fail "Composer not installed. Run: releasepanel bootstrap"
    fi
}

php_binary() {
    local binary="php${RELEASEPANEL_PHP_VERSION}"

    if command -v "${binary}" >/dev/null 2>&1; then
        command -v "${binary}"
        return 0
    fi

    if command -v php >/dev/null 2>&1 && php -r "exit(PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION === '${RELEASEPANEL_PHP_VERSION}' ? 0 : 1);" >/dev/null 2>&1; then
        command -v php
        return 0
    fi

    fail "PHP ${RELEASEPANEL_PHP_VERSION} CLI missing. Run: releasepanel install-php ${RELEASEPANEL_PHP_VERSION}"
}

# Prune undecryptable servers rows, relink releasepanel-app to the host runner, refresh heartbeats.
# Call load_env() first with the panel toolkit env (e.g. sites/releasepanel-app/production.env).
releasepanel_heal_self_host_runner_credentials() {
    local panel_live
    local branch

    panel_live="$(readlink -f "${RELEASEPANEL_CURRENT}")"
    if [ ! -f "${panel_live}/artisan" ]; then
        warn "releasepanel_heal_self_host_runner_credentials: no artisan at ${RELEASEPANEL_CURRENT} -> ${panel_live}; skip."
        return 0
    fi

    if [ -z "${DOMAIN:-}" ]; then
        warn "releasepanel_heal_self_host_runner_credentials: DOMAIN unset; skip."
        return 0
    fi

    branch="${BRANCH:-main}"

    case "${RELEASEPANEL_SKIP_PRUNE_UNDECRYPTABLE_SERVERS:-false}" in
        1 | true | TRUE | yes | YES)
            log "Skipping releasepanel:prune-undecryptable-servers (RELEASEPANEL_SKIP_PRUNE_UNDECRYPTABLE_SERVERS=true)."
            ;;
        *)
            log "Pruning server rows that fail decryption with current APP_KEY."
            run_as_app_user_in "${panel_live}" "$(php_binary)" artisan releasepanel:prune-undecryptable-servers --no-interaction || return 1
            ;;
    esac

    log "Syncing ReleasePanel site and host runner (releasepanel:sync-self-site)."
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan releasepanel:sync-self-site "${DOMAIN}" \
        --repo="${REPO_URL}" \
        --branch="${branch}" \
        --deploy-path="${BASE_PATH}" \
        --php="${PHP_VERSION}" || return 1

    log "Refreshing server reachability (servers:heartbeat)."
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan servers:heartbeat --no-interaction || return 1
}

releasepanel_composer_path() {
    if [ -x /usr/local/bin/composer ]; then
        printf '%s\n' /usr/local/bin/composer
        return 0
    fi

    command -v composer
}

local_http_check() {
    local strict="${1:-false}"
    local health_path="${RELEASEPANEL_HEALTH_PATH:-/up}"
    local paths=("${health_path}" /health /)
    local path
    local health_code=""
    local root_code

    for path in "${paths[@]}"; do
        [ -z "${path}" ] && continue
        health_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: ${RELEASEPANEL_SERVER_NAME}" "http://127.0.0.1${path}" || true)"
        if [ "${health_code}" = "200" ] || [ "${health_code}" = "302" ]; then
            return 0
        fi
    done

    if [ "${health_code}" != "404" ] && [ "${health_code}" != "000" ] && [ -n "${health_code}" ]; then
        echo "[warning] HTTP health checks failed (last ${health_code})"
        [ "${strict}" = "true" ] && return 1
        return 0
    fi

    root_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: ${RELEASEPANEL_SERVER_NAME}" http://127.0.0.1 || true)"
    if [ "${root_code}" = "200" ] || [ "${root_code}" = "302" ]; then
        return 0
    fi

    if [ "${root_code}" = "000" ]; then
        echo "[warning] app not responding"
    else
        echo "[warning] health paths not found; fallback / returned ${root_code}"
    fi

    [ "${strict}" = "true" ] && return 1
}

local_http_redirect_check() {
    local strict="${1:-false}"
    local root_code

    root_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -H "Host: ${RELEASEPANEL_SERVER_NAME}" \
        http://127.0.0.1 || true)"

    case "${root_code}" in
        200 | 301 | 302 | 308)
            return 0
            ;;
        000)
            echo "[warning] HTTP check did not connect."
            ;;
        *)
            echo "[warning] HTTP check returned ${root_code}; expected 200 or redirect."
            ;;
    esac

    [ "${strict}" = "true" ] && return 1
}

local_https_check() {
    local strict="${1:-false}"
    local le_cert="/etc/letsencrypt/live/${RELEASEPANEL_SERVER_NAME}/fullchain.pem"
    local self_cert="/etc/ssl/releasepanel/${RELEASEPANEL_SERVER_NAME}/fullchain.pem"
    local cert=""
    local health_path="${RELEASEPANEL_HEALTH_PATH:-/up}"
    local paths=("${health_path}" "/health" "/")
    local path
    local health_code

    if [ -f "${le_cert}" ]; then
        cert="${le_cert}"
    elif [ -f "${self_cert}" ]; then
        cert="${self_cert}"
        echo "[info] Using self-signed certificate at ${self_cert} for HTTPS health check."
    fi

    if [ -z "${cert}" ] || [ ! -f "${cert}" ]; then
        echo "[warning] No local TLS certificate (Let's Encrypt or /etc/ssl/releasepanel). APP_URL may still use HTTPS (edge TLS or certbot later). Verifying app over HTTP on loopback."
        local_http_check "${strict}"
        return $?
    fi

    for path in "${paths[@]}"; do
        [ -z "${path}" ] && continue

        health_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 \
            --resolve "${RELEASEPANEL_SERVER_NAME}:443:127.0.0.1" \
            "https://${RELEASEPANEL_SERVER_NAME}${path}" || true)"

        if [ "${health_code}" = "200" ] || [ "${health_code}" = "302" ]; then
            return 0
        fi
    done

    if [ "${health_code:-000}" = "000" ]; then
        echo "[warning] HTTPS app health check did not connect."
    else
        echo "[warning] HTTPS app health checks failed; last response was ${health_code}."
    fi

    [ "${strict}" = "true" ] && return 1
}

php_fpm_socket() {
    local configured_socket="/run/php/php${RELEASEPANEL_PHP_VERSION}-fpm.sock"

    if [ -S "${configured_socket}" ]; then
        printf '%s\n' "${configured_socket}"
        return 0
    fi

    return 1
}

ensure_php_fpm_socket() {
    local socket

    socket="$(php_fpm_socket || true)"

    if [ -z "${socket}" ] || [ ! -S "${socket}" ]; then
        fail "PHP-FPM socket missing at /run/php/php${RELEASEPANEL_PHP_VERSION}-fpm.sock. Run: releasepanel install-php ${RELEASEPANEL_PHP_VERSION}"
    fi

    RELEASEPANEL_PHP_FPM_SOCK="${socket}"
    export RELEASEPANEL_PHP_FPM_SOCK
}

php_fpm_service() {
    local service="php${RELEASEPANEL_PHP_VERSION}-fpm"

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${service}.service" >/dev/null 2>&1; then
        printf '%s\n' "${service}"
        return 0
    fi

    if command -v service >/dev/null 2>&1 && service "${service}" status >/dev/null 2>&1; then
        printf '%s\n' "${service}"
        return 0
    fi

    return 1
}

reload_php_fpm() {
    local service="${1:-}"

    if [ -z "${service}" ]; then
        service="$(php_fpm_service || true)"
    fi

    if [ -z "${service}" ]; then
        warn "Could not detect PHP-FPM service. Reload OPcache/PHP-FPM manually."
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable "${service}" >/dev/null 2>&1 || true
        systemctl start "${service}" || true
        systemctl reload "${service}" || systemctl restart "${service}"
    else
        service "${service}" reload || service "${service}" restart
    fi

    ensure_php_fpm_socket
}

restart_workers() {
    if command -v supervisorctl >/dev/null 2>&1; then
        local process_names

        supervisorctl reread || true
        supervisorctl update || true
        process_names="$(supervisorctl status 2>/dev/null | awk -v prefix="${RELEASEPANEL_PROGRAM_PREFIX}-" '$1 ~ "^" prefix { print $1 }' || true)"
        if [ -n "${process_names}" ]; then
            while IFS= read -r process_name; do
                [ -n "${process_name}" ] && supervisorctl restart "${process_name}" || true
            done <<< "${process_names}"
        else
            warn "Supervisor workers for ${RELEASEPANEL_ENV} are not installed yet; skipping worker restart."
        fi
    fi
}

print_deploy_summary() {
    local sha="${1:-unknown}"

    echo ""
    echo "[releasepanel] Deploy complete"
    echo "Env: ${RELEASEPANEL_ENV}"
    echo "Domain: ${RELEASEPANEL_SERVER_NAME}"
    echo "Path: ${RELEASEPANEL_BASE}"
    echo "Commit: ${sha}"
    echo ""
}

artisan_in_release() {
    local release="$1"
    shift

    if [ ! -f "${release}/vendor/autoload.php" ]; then
        fail "vendor/autoload.php missing in ${release}; refusing to run artisan."
    fi

    run_as_app_user_in "${release}" "$(php_binary)" artisan "$@"
}

safe_artisan() {
    local command="$1"
    local release="${RELEASE_PATH:?RELEASE_PATH must be set before safe_artisan}"

    if [ ! -f "${release}/vendor/autoload.php" ]; then
        warn "Skipping artisan ${command}; vendor/autoload.php is missing in ${release}."
        return 0
    fi

    sudo -Hu "${RELEASEPANEL_APP_USER}" bash -lc "cd $(printf '%q' "${release}") && $(printf '%q' "$(php_binary)") artisan ${command}" || true
}

release_has_vendor() {
    [ -f "$1/vendor/autoload.php" ]
}

write_deploy_stamp() {
    local release="$1"
    local status="$2"
    local sha="${3:-unknown}"
    local stamp="${RELEASEPANEL_SHARED}/deploy.json"
    local history="${RELEASEPANEL_SHARED}/deploy-history.jsonl"
    local now

    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "${RELEASEPANEL_SHARED}"

    cat > "${stamp}" <<JSON
{
  "status": "${status}",
  "release": "${release}",
  "sha": "${sha}",
  "branch": "${RELEASEPANEL_BRANCH}",
  "deployed_at": "${now}"
}
JSON

    printf '{"status":"%s","release":"%s","sha":"%s","branch":"%s","deployed_at":"%s"}\n' \
        "${status}" "${release}" "${sha}" "${RELEASEPANEL_BRANCH}" "${now}" >> "${history}"
    chown "${RELEASEPANEL_APP_USER}:${RELEASEPANEL_FILE_GROUP}" "${stamp}" "${history}" || true
}

detect_package_script() {
    local release="$1"
    local script_name

    for script_name in build production prod; do
        if run_as_app_user_in "${release}" node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts['${script_name}'] ? 0 : 1)" >/dev/null 2>&1; then
            printf '%s\n' "${script_name}"
            return 0
        fi
    done

    return 1
}

package_script_command() {
    local release="$1"
    local script_name="$2"

    run_as_app_user_in "${release}" node -e "const p=require('./package.json'); console.log(p.scripts['${script_name}'] || '')"
}

detect_and_run_asset_build() {
    local release="$1"
    local script_name
    local script_command

    if [ "${RELEASEPANEL_RUN_NPM}" != "true" ]; then
        warn "RELEASEPANEL_RUN_NPM is not true; skipping npm install/build."
        return 0
    fi

    if [ "${RELEASEPANEL_SKIP_ASSET_BUILD}" = "true" ]; then
        warn "RELEASEPANEL_SKIP_ASSET_BUILD=true; skipping asset build."
        return 0
    fi

    if [ ! -f "${release}/package.json" ]; then
        warn "package.json missing; skipping npm install/build."
        return 0
    fi

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        warn "node/npm not installed; skipping npm build."
        return 0
    fi

    if [ -f "${release}/package-lock.json" ]; then
        log "Installing npm dependencies with npm ci (clean node_modules first)."
        run_as_app_user_in "${release}" rm -rf node_modules
        if ! run_as_app_user_in "${release}" npm ci; then
            warn "npm ci failed; retrying with npm install (Rolldown optional native binding workaround)."
            run_as_app_user_in "${release}" rm -rf node_modules
            run_as_app_user_in "${release}" npm install --no-audit --no-fund
        fi
    else
        log "Installing npm dependencies with npm install."
        run_as_app_user_in "${release}" rm -rf node_modules
        run_as_app_user_in "${release}" npm install --no-audit --no-fund
    fi

    script_name="$(detect_package_script "${release}" || true)"
    if [ -z "${script_name}" ]; then
        warn "No npm build/production/prod script found; skipping asset build."
        return 0
    fi

    script_command="$(package_script_command "${release}" "${script_name}")"

    if [[ "${script_command}" == *mix* ]] && [ ! -f "${release}/webpack.mix.js" ]; then
        warn "Selected npm script '${script_name}' uses Mix, but webpack.mix.js is missing; skipping asset build."
        return 0
    fi

    if [[ "${script_command}" == *vite* ]] && [ ! -f "${release}/vite.config.js" ] && [ ! -f "${release}/vite.config.ts" ]; then
        warn "Selected npm script '${script_name}' uses Vite, but vite.config.js/ts is missing; skipping asset build."
        return 0
    fi

    log "Running npm run ${script_name}."
    run_as_app_user_in "${release}" npm run "${script_name}"
}

current_public_ip() {
    curl -fsS https://api.ipify.org 2>/dev/null || curl -fsS https://ifconfig.me 2>/dev/null || true
}

domain_ips() {
    local domain="$1"
    getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u || true
}

confirm() {
    local prompt="$1"
    local answer

    read -r -p "${prompt} [type YES]: " answer
    [ "${answer}" = "YES" ]
}
