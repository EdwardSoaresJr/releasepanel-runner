#!/usr/bin/env bash

normalize_site_env() {
    local input="$1"

    if [[ "${input}" =~ ^([A-Za-z0-9_-]+)[[:space:]]+([A-Za-z0-9_-]+)$ ]]; then
        printf '%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    printf '%s\n' "${input}"
}

resolve_site_env_name() {
    local site_env
    local env_file
    local site
    local env

    site_env="$(normalize_site_env "$1")"

    for env_file in "${RELEASEPANEL_TOOLKIT_DIR}/sites/"*/*.env; do
        [ -e "${env_file}" ] || continue

        env="$(basename "${env_file}" .env)"
        site="$(basename "$(dirname "${env_file}")")"

        if [ "${site}-${env}" = "${site_env}" ]; then
            SITE_SLUG="${site}"
            ENV_SLUG="${env}"
            RELEASEPANEL_DEPLOY_ENV="${env_file}"
            export SITE_SLUG ENV_SLUG RELEASEPANEL_DEPLOY_ENV
            SITE_ENV_NAME="${site_env}"
            export SITE_ENV_NAME
            return 0
        fi
    done

    return 1
}

load_site_env_args() {
    if [ "$#" -lt 1 ]; then
        echo "[error] Usage: ${0##*/} <site> <env> [options] or <site-env> [options]" >&2
        exit 2
    fi

    if [ "$#" -ge 2 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]+$' && printf '%s' "$2" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        SITE_SLUG="$1"
        ENV_SLUG="$2"
        shift 2
        RELEASEPANEL_DEPLOY_ENV="${RELEASEPANEL_TOOLKIT_DIR}/sites/${SITE_SLUG}/${ENV_SLUG}.env"
        SITE_ENV_NAME="${SITE_SLUG}-${ENV_SLUG}"
    elif resolve_site_env_name "$1"; then
        shift
    else
        echo "[error] Missing site environment config for: $1" >&2
        exit 2
    fi

    if ! printf '%s' "${SITE_SLUG}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        echo "[error] Invalid site slug: ${SITE_SLUG}" >&2
        exit 2
    fi

    if ! printf '%s' "${ENV_SLUG}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        echo "[error] Invalid environment slug: ${ENV_SLUG}" >&2
        exit 2
    fi

    if [ ! -f "${RELEASEPANEL_DEPLOY_ENV}" ] || [ ! -r "${RELEASEPANEL_DEPLOY_ENV}" ] || [ ! -s "${RELEASEPANEL_DEPLOY_ENV}" ]; then
        printf '%s\n' "[warning] Toolkit site env missing, empty, or unreadable at ${RELEASEPANEL_DEPLOY_ENV} — continuing (defaults + panel-injected env when used)." >&2
    fi

    export SITE_SLUG ENV_SLUG RELEASEPANEL_DEPLOY_ENV SITE_ENV_NAME
    SITE_REMAINING_ARGS=("$@")
}
