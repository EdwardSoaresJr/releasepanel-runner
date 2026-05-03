#!/usr/bin/env bash
set -Eeuo pipefail

RELEASEPANEL_TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=site-runner-common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-runner-common.sh"

load_site_env_args "$@"

deploy_args=()
for arg in "${SITE_REMAINING_ARGS[@]}"; do
    case "${arg}" in
        --skip-route-cache) deploy_args+=("--skip-route-cache") ;;
        --strict) deploy_args+=("--require-redis" "--require-db" "--rollback-on-https-fail") ;;
        *) echo "[error] Unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

exec "${RELEASEPANEL_TOOLKIT_DIR}/scripts/deploy.sh" "${SITE_ENV_NAME}" "${deploy_args[@]}"
