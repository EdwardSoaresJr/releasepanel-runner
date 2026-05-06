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

# Interactive prompts matching scripts/bootstrap-releasepanel.sh (TTY + env pre-fill).
prompt_value() {
    local var_name="$1"
    local prompt="$2"
    local default="${3:-}"
    local value="${!var_name:-}"

    if [ -n "${value}" ]; then
        printf '%s' "${value}"
        return 0
    fi

    if [ ! -r /dev/tty ]; then
        fail "${var_name} is required when no interactive terminal is available."
    fi

    if [ -n "${default}" ]; then
        read -r -p "${prompt} [${default}]: " value < /dev/tty
        value="${value:-${default}}"
    else
        read -r -p "${prompt}: " value < /dev/tty
    fi

    [ -n "${value}" ] || fail "${var_name} is required."
    printf '%s' "${value}"
}

prompt_secret() {
    local var_name="$1"
    local prompt="$2"
    local value="${!var_name:-}"

    if [ -n "${value}" ]; then
        printf '%s' "${value}"
        return 0
    fi

    if [ ! -r /dev/tty ]; then
        fail "${var_name} is required when no interactive terminal is available."
    fi

    read -r -s -p "${prompt}: " value < /dev/tty
    printf '\n' > /dev/tty
    [ -n "${value}" ] || fail "${var_name} is required."
    printf '%s' "${value}"
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

    if [ -n "${SITE_SLUG:-}" ] && [ -n "${ENV_SLUG:-}" ] && [ -n "${RELEASEPANEL_DEPLOY_ENV:-}" ]; then
        return 0
    fi

    if resolve_site_env_config "${env_name}"; then
        return 0
    fi

    return 1
}

__rp_is_site_toolkit_env_path() {
    case "${1:-}" in
        */sites/*/*.env) return 0 ;;
        *) return 1 ;;
    esac
}

# Missing, empty (0 bytes), or unreadable site toolkit fragment — treat like missing for optional deploy.
__rp_site_toolkit_env_unusable() {
    local p="${1:-}"
    if ! __rp_is_site_toolkit_env_path "${p}"; then
        return 1
    fi
    if [ ! -f "${p}" ] || [ ! -r "${p}" ]; then
        return 0
    fi
    if [ ! -s "${p}" ]; then
        return 0
    fi
    return 1
}

load_env() {
    unset RELEASEPANEL_SITE_ENV_MISSING 2>/dev/null || true
    local __rp_missing_site_env=0

    if __rp_is_site_toolkit_env_path "${RELEASEPANEL_DEPLOY_ENV}"; then
        if __rp_site_toolkit_env_unusable "${RELEASEPANEL_DEPLOY_ENV}"; then
            if [ "${RELEASEPANEL_REQUIRE_SITE_TOOLKIT_ENV:-0}" = "1" ]; then
                fail "Missing, empty, or unreadable toolkit site env ${RELEASEPANEL_DEPLOY_ENV} (set RELEASEPANEL_REQUIRE_SITE_TOOLKIT_ENV=0 to allow deploy without it)."
            fi
            warn "Site toolkit env missing, empty, or unreadable at ${RELEASEPANEL_DEPLOY_ENV} — continuing with slug defaults and process environment (panel job injects repo/domain when used)."
            __rp_missing_site_env=1
            export RELEASEPANEL_SITE_ENV_MISSING=1
        fi
    elif [ ! -f "${RELEASEPANEL_DEPLOY_ENV}" ]; then
        if [ ! -f "${RELEASEPANEL_TOOLKIT_DIR}/.env.example" ]; then
            fail "Missing ${RELEASEPANEL_DEPLOY_ENV} and ${RELEASEPANEL_TOOLKIT_DIR}/.env.example."
        fi

        echo "[releasepanel] Step: Creating deploy.env from .env.example"
        cp "${RELEASEPANEL_TOOLKIT_DIR}/.env.example" "${RELEASEPANEL_DEPLOY_ENV}"
        chmod 600 "${RELEASEPANEL_DEPLOY_ENV}"
        warn "Created ${RELEASEPANEL_DEPLOY_ENV}. Review it before SSL/certbot or production deploy steps."
    fi

    if [ "${__rp_missing_site_env}" -eq 0 ]; then
        set -a
        # shellcheck disable=SC1090
        . "${RELEASEPANEL_DEPLOY_ENV}"
        set +a
    fi

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
        if [ "${RELEASEPANEL_SITE_ENV_MISSING:-0}" = "1" ]; then
            warn "RELEASEPANEL_SERVER_NAME is unset (no toolkit .env). Set domain on the environment in the panel or sync toolkit envs before nginx/SSL steps."
            return 0
        fi
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

    if grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "${file}" \
        && ! grep -qE '^[[:space:]]*listen[[:space:]]+.*443' "${file}"; then
        fail "nginx config ${file} sets ssl_certificate but has no listen 443 — add e.g. \"listen 443 ssl http2;\" to the TLS server block."
    fi
}

# Every ssl_certificate PEM path in the file exists (ignores ssl_certificate_key lines).
nginx_ssl_certificate_pems_exist() {
    local file="$1"
    local path

    if [ ! -f "${file}" ]; then
        return 1
    fi

    while IFS= read -r line; do
        path="$(printf '%s' "${line}" | awk '{print $2}' | tr -d ';')"
        [ -n "${path}" ] || continue
        [ -f "${path}" ] || return 1
    done < <(grep -E '^[[:space:]]*ssl_certificate[[:space:]]' "${file}" | grep -Fv 'ssl_certificate_key')

    return 0
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

# Directory containing server.js.
# Prefer explicit RELEASEPANEL_RUNNER_DIR, then /opt/releasepanel-runner (control-plane
# layout: git clone from releasepanel-runner), then a sibling ../releasepanel-runner
# checkout (developer machine), then bundle layout (server.js next to toolkit/), finally
# legacy monorepo toolkit/runner/ (deprecated).
releasepanel_resolve_runner_directory() {
    local toolkit="${RELEASEPANEL_TOOLKIT_DIR:-/opt/releasepanel-deploy}"

    if [ -n "${RELEASEPANEL_RUNNER_DIR:-}" ] && [ -f "${RELEASEPANEL_RUNNER_DIR}/server.js" ]; then
        printf '%s\n' "$(cd "${RELEASEPANEL_RUNNER_DIR}" && pwd)"
        return 0
    fi

    local opt_public="/opt/releasepanel-runner"
    if [ -f "${opt_public}/server.js" ]; then
        printf '%s\n' "${opt_public}"
        return 0
    fi

    local sibling="${toolkit}/../releasepanel-runner"
    if [ -f "${sibling}/server.js" ]; then
        printf '%s\n' "$(cd "${sibling}" && pwd)"
        return 0
    fi

    if [ -f "${toolkit}/../server.js" ]; then
        printf '%s\n' "$(cd "${toolkit}/.." && pwd)"
        return 0
    fi

    printf '%s\n' "${toolkit}/runner"
}

releasepanel_write_managed_agent_systemd_unit() {
    local runner_dir="$1"
    local toolkit_dir="$2"
    local node_bin="${3:-}"
    local service_target="/etc/systemd/system/managed-deploy-agent.service"
    local service_source="${toolkit_dir}/systemd/managed-deploy-agent.service.example"

    if [ -z "${node_bin}" ]; then
        node_bin="$(command -v node 2>/dev/null || true)"
    fi
    if [ -z "${node_bin}" ]; then
        node_bin="/usr/bin/node"
    fi
    if [ ! -x "${node_bin}" ]; then
        warn "releasepanel_write_managed_agent_systemd_unit: node binary not executable at ${node_bin}"
        return 1
    fi

    if [ ! -f "${service_source}" ]; then
        warn "releasepanel_write_managed_agent_systemd_unit: missing ${service_source}"
        return 1
    fi

    # Legacy templates used __RELEASEPANEL_TOOLKIT_DIR__/runner; current use __RUNNER_DIR__ + __NODE_BIN__.
    # Order: longer / more specific patterns first.
    sed -e "s|__RELEASEPANEL_TOOLKIT_DIR__/runner|${runner_dir}|g" \
        -e "s|__RELEASEPANEL_TOOLKIT_DIR__|${toolkit_dir}|g" \
        -e "s|__RUNNER_DIR__|${runner_dir}|g" \
        -e "s|__NODE_BIN__|${node_bin}|g" \
        "${service_source}" > "${service_target}"

    if grep -qE '__[A-Z][A-Z0-9_]*__' "${service_target}"; then
        warn "releasepanel_write_managed_agent_systemd_unit: unreplaced placeholders in ${service_target} — check ${service_source}"
        return 1
    fi

    log "Systemd unit: ${service_target}"
}

# Reproducible node_modules + refreshed unit + restart after toolkit pull (self-update) or manual repair.
releasepanel_managed_agent_install_node_modules() {
    local runner_dir="$1"
    local npm_timeout="${RELEASEPANEL_NPM_TIMEOUT_SECONDS:-900}"

    __releasepanel_npm() {
        if command -v timeout >/dev/null 2>&1; then
            timeout "${npm_timeout}" "$@"
        else
            "$@"
        fi
    }

    trap 'unset -f __releasepanel_npm 2>/dev/null' RETURN

    if ! (
        cd "${runner_dir}" || exit 1
        if [ -f package-lock.json ]; then
            prefer_offline=(--prefer-offline)
            attempt=1
            while [ "${attempt}" -le 3 ]; do
                if __releasepanel_npm npm ci --omit=dev --no-audit --no-fund "${prefer_offline[@]}"; then
                    break
                fi
                if [ "${attempt}" -eq 3 ]; then
                    warn "Managed deploy agent: npm ci failed after 3 attempts; falling back to npm install."
                    __releasepanel_npm npm install --omit=dev --no-audit --no-fund || exit 1
                    break
                fi
                warn "Managed deploy agent: npm ci failed (attempt ${attempt}/3); retrying..."
                sleep $((attempt * 4))
                attempt=$((attempt + 1))
            done
        else
            __releasepanel_npm npm install --omit=dev --no-audit --no-fund || exit 1
        fi
    ); then
        return 1
    fi

    if ! ( cd "${runner_dir}" && node --check server.js ); then
        printf '%s\n' "[releasepanel] error: server.js syntax check failed (${runner_dir})." >&2
        return 1
    fi

    if ! (
        cd "${runner_dir}" || exit 1
        node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));for(const d of Object.keys(p.dependencies||{})){require(d);}"
    ); then
        printf '%s\n' "[releasepanel] error: Managed deploy agent dependencies incomplete after npm install (${runner_dir}). Try: cd ${runner_dir} && npm ci --omit=dev" >&2
        return 1
    fi
}

releasepanel_refresh_managed_deploy_agent() {
    case "${RELEASEPANEL_SKIP_MANAGED_AGENT_REFRESH:-false}" in
        1 | true | TRUE | yes | YES)
            log "Skipping managed deploy agent refresh (RELEASEPANEL_SKIP_MANAGED_AGENT_REFRESH=true)."
            return 0
            ;;
    esac

    local toolkit="${RELEASEPANEL_TOOLKIT_DIR:-/opt/releasepanel-deploy}"
    local runner_dir
    runner_dir="$(releasepanel_resolve_runner_directory)"

    if [ ! -f "${runner_dir}/package.json" ]; then
        warn "releasepanel_refresh_managed_deploy_agent: no package.json in ${runner_dir}; skip."
        return 0
    fi

    log "Managed deploy agent: npm install, systemd unit, service restart (${runner_dir})."
    releasepanel_managed_agent_install_node_modules "${runner_dir}" || {
        warn "releasepanel_refresh_managed_deploy_agent: npm failed in ${runner_dir}."
        return 1
    }

    if [ -f "${runner_dir}/.env" ]; then
        chmod 600 "${runner_dir}/.env"
    fi

    releasepanel_write_managed_agent_systemd_unit "${runner_dir}" "${toolkit}" || return 1

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "releasepanel_refresh_managed_deploy_agent: systemctl missing; restart the agent manually."
        return 0
    fi

    systemctl daemon-reload
    systemctl enable managed-deploy-agent 2>/dev/null || true

    if systemctl is-active --quiet managed-deploy-agent 2>/dev/null; then
        systemctl restart managed-deploy-agent || warn "releasepanel_refresh_managed_deploy_agent: systemctl restart failed."
        releasepanel_runner_probe_health "${runner_dir}" 25 || warn "releasepanel_refresh_managed_deploy_agent: runner /health probe failed; check journalctl."
    fi
}

releasepanel_dotenv_get() {
    local file="$1"
    local key="$2"
    local line
    line="$(grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | head -1 || true)"
    if [ -z "${line}" ]; then
        return 1
    fi
    local val="${line#*=}"
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    val="$(printf '%s' "${val}" | tr -d '\r')"
    printf '%s\n' "${val}"
}

# Probe loopback /health with API key until success or timeout (fresh VPS bootstrap guardrail).
releasepanel_runner_probe_health() {
    local runner_dir="$1"
    local max_wait="${2:-45}"
    local env_file="${runner_dir}/.env"
    local key=""
    local host="127.0.0.1"
    local port="9000"
    local elapsed=0

    if [ ! -f "${env_file}" ]; then
        printf '%s\n' "[releasepanel] error: runner .env missing (${env_file})." >&2
        return 1
    fi

    key="$(releasepanel_dotenv_get "${env_file}" MANAGED_AGENT_RUNNER_KEY 2>/dev/null || true)"
    if [ -z "${key}" ] || [ "${key}" = "CHANGE_ME" ]; then
        key="$(releasepanel_dotenv_get "${env_file}" RELEASEPANEL_RUNNER_KEY 2>/dev/null || true)"
    fi
    if [ -z "${key}" ] || [ "${key}" = "CHANGE_ME" ]; then
        printf '%s\n' "[releasepanel] error: runner API key missing or CHANGE_ME (${env_file})." >&2
        return 1
    fi

    local rh rp
    rh="$(releasepanel_dotenv_get "${env_file}" MANAGED_AGENT_RUNNER_HOST 2>/dev/null || true)"
    if [ -z "${rh}" ]; then
        rh="$(releasepanel_dotenv_get "${env_file}" RELEASEPANEL_RUNNER_HOST 2>/dev/null || true)"
    fi
    rp="$(releasepanel_dotenv_get "${env_file}" MANAGED_AGENT_RUNNER_PORT 2>/dev/null || true)"
    if [ -z "${rp}" ]; then
        rp="$(releasepanel_dotenv_get "${env_file}" RELEASEPANEL_RUNNER_PORT 2>/dev/null || true)"
    fi
    [ -n "${rh}" ] && host="${rh}"
    [ -n "${rp}" ] && port="${rp}"
    if [ "${host}" = "0.0.0.0" ]; then
        host="127.0.0.1"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        warn "releasepanel_runner_probe_health: curl missing; skipping HTTP probe."
        return 0
    fi

    while [ "${elapsed}" -lt "${max_wait}" ]; do
        if systemctl is-active --quiet managed-deploy-agent 2>/dev/null; then
            if curl -fsS --connect-timeout 2 --max-time 8 \
                -H "X-Managed-Agent-Key: ${key}" \
                "http://${host}:${port}/health" >/dev/null 2>&1; then
                log "Managed deploy agent healthy (http://${host}:${port}/health)."
                return 0
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    printf '%s\n' "[releasepanel] error: managed-deploy-agent not healthy within ${max_wait}s." >&2
    printf '%s\n' "[releasepanel] hint: journalctl -u managed-deploy-agent -n 80 --no-pager" >&2
    printf '%s\n' "[releasepanel] hint: cd ${runner_dir} && sudo npm ci --omit=dev && sudo systemctl restart managed-deploy-agent" >&2
    return 1
}

releasepanel_dotenv_set_key() {
    local file="$1"
    local key="$2"
    local value="$3"

    RELEASEPANEL_DOTENV_PATH="${file}" \
    RELEASEPANEL_DOTENV_KEY="${key}" \
    RELEASEPANEL_DOTENV_VAL="${value}" \
        python3 <<'PY'
import os
from pathlib import Path

path = Path(os.environ["RELEASEPANEL_DOTENV_PATH"])
key = os.environ["RELEASEPANEL_DOTENV_KEY"]
value = os.environ["RELEASEPANEL_DOTENV_VAL"]
lines = path.read_text().splitlines()
out = []
seen = False
prefix = key + "="
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith(prefix):
        out.append(key + "=" + value)
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(key + "=" + value)
path.write_text("\n".join(out).rstrip() + "\n")
PY
}

# Node agent reads MANAGED_AGENT_RUNNER_KEY / RELEASEPANEL_RUNNER_KEY only from its own .env.
# Laravel heal (sync-self-site) updates the DB but never rewrote runner/.env — drift causes 401 Unauthorized.
releasepanel_align_host_runner_dotenv_with_shared_env() {
    local shared_env="${RELEASEPANEL_SHARED}/.env"
    local runner_dir=""
    local runner_env=""
    local panel_key=""
    local cur_m cur_l

    if [ ! -f "${shared_env}" ]; then
        warn "releasepanel_align_host_runner_dotenv: missing ${shared_env}"
        return 0
    fi

    panel_key="$(releasepanel_dotenv_get "${shared_env}" RELEASEPANEL_RUNNER_KEY || true)"
    if [ -z "${panel_key}" ]; then
        warn "releasepanel_align_host_runner_dotenv: RELEASEPANEL_RUNNER_KEY is empty in ${shared_env}"
        return 0
    fi

    runner_dir="$(releasepanel_resolve_runner_directory)"

    runner_env="${runner_dir}/.env"
    if [ ! -f "${runner_env}" ]; then
        warn "releasepanel_align_host_runner_dotenv: missing ${runner_env} — run: sudo releasepanel runner"
        return 0
    fi

    cur_m="$(releasepanel_dotenv_get "${runner_env}" MANAGED_AGENT_RUNNER_KEY || true)"
    cur_l="$(releasepanel_dotenv_get "${runner_env}" RELEASEPANEL_RUNNER_KEY || true)"

    if [ "${cur_m}" = "${panel_key}" ] && [ "${cur_l}" = "${panel_key}" ]; then
        log "Host runner .env keys already match panel shared/.env (RELEASEPANEL_RUNNER_KEY)."
        return 0
    fi

    log "Writing host runner ${runner_env} keys to match panel ${shared_env} (MANAGED_AGENT_* + RELEASEPANEL_*)."
    releasepanel_dotenv_set_key "${runner_env}" MANAGED_AGENT_RUNNER_KEY "${panel_key}"
    releasepanel_dotenv_set_key "${runner_env}" RELEASEPANEL_RUNNER_KEY "${panel_key}"
    chmod 600 "${runner_env}"

    if command -v systemctl >/dev/null 2>&1; then
        log "Restarting managed-deploy-agent to load the updated key."
        systemctl restart managed-deploy-agent 2>/dev/null ||
            warn "Could not restart managed-deploy-agent (install the unit or run the runner manually)."
    fi
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

    log "Clearing Laravel config cache so releasepanel:sync-self-site reads current shared/.env."
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan config:clear --no-interaction || return 1

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

    releasepanel_align_host_runner_dotenv_with_shared_env || true

    log "Refreshing server reachability (servers:heartbeat)."
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan servers:heartbeat --no-interaction || return 1

    log "Rebuilding Laravel caches after heal."
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan config:cache --no-interaction || warn "config:cache after heal failed."
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan route:cache --no-interaction || true
    run_as_app_user_in "${panel_live}" "$(php_binary)" artisan view:cache --no-interaction || true
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
    local cert=""
    local health_path="${RELEASEPANEL_HEALTH_PATH:-/up}"
    local paths=("${health_path}" "/health" "/")
    local path
    local health_code
    local last_code=""
    local loop_ip

    if [ -f "${le_cert}" ]; then
        cert="${le_cert}"
    fi

    if [ -z "${cert}" ] || [ ! -f "${cert}" ]; then
        echo "[warning] No local Let's Encrypt certificate yet. Verifying app over HTTP on loopback."
        local_http_check "${strict}"
        return $?
    fi

    for path in "${paths[@]}"; do
        [ -z "${path}" ] && continue
        for loop_ip in 127.0.0.1 '[::1]'; do
            health_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 \
                --resolve "${RELEASEPANEL_SERVER_NAME}:443:${loop_ip}" \
                "https://${RELEASEPANEL_SERVER_NAME}${path}" 2>/dev/null || true)"
            last_code="${health_code}"
            if [ "${health_code}" = "200" ] || [ "${health_code}" = "302" ]; then
                return 0
            fi
        done
    done

    if [ "${last_code:-000}" = "000" ]; then
        echo "[warning] HTTPS app health check did not connect (tried 127.0.0.1 and ::1 on port 443)."
        echo "[hint] Is nginx listening on 443? Run: ss -tlnp | grep ':443'  —  and: grep -n listen /etc/nginx/sites-enabled/*-https.conf"
    else
        echo "[warning] HTTPS app health checks failed; last response was ${last_code}."
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
