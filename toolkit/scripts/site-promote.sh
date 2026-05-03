#!/usr/bin/env bash
set -Eeuo pipefail

RELEASEPANEL_TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -ne 3 ]; then
    echo "[error] Usage: ${0##*/} <site> <from-env> <to-env>" >&2
    exit 2
fi

site_slug="$1"
from_env="$2"
to_env="$3"

for value in "${site_slug}" "${from_env}" "${to_env}"; do
    if ! printf '%s' "${value}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        echo "[error] Invalid slug: ${value}" >&2
        exit 2
    fi
done

config_path_for() {
    local env_slug="$1"

    printf '%s/sites/%s/%s.env\n' "${RELEASEPANEL_TOOLKIT_DIR}" "${site_slug}" "${env_slug}"
}

source_config="$(config_path_for "${from_env}")"
target_config="$(config_path_for "${to_env}")"

[ -f "${source_config}" ] || { echo "[error] Missing source config: ${source_config}" >&2; exit 2; }
[ -f "${target_config}" ] || { echo "[error] Missing target config: ${target_config}" >&2; exit 2; }

target_base="$(RELEASEPANEL_DEPLOY_ENV="${target_config}" bash -c '. "'"${RELEASEPANEL_TOOLKIT_DIR}"'/lib/common.sh"; load_env >/dev/null; printf "%s" "${RELEASEPANEL_BASE}"')"
[ -f "${target_base}/shared/.env" ] || { echo "[error] Target shared .env is missing: ${target_base}/shared/.env" >&2; exit 1; }

source_current="$(RELEASEPANEL_DEPLOY_ENV="${source_config}" bash -c '. "'"${RELEASEPANEL_TOOLKIT_DIR}"'/lib/common.sh"; load_env >/dev/null; readlink -f "${RELEASEPANEL_CURRENT}"')"
[ -n "${source_current}" ] && [ -d "${source_current}" ] || { echo "[error] Source current release is missing." >&2; exit 1; }

commit_sha="$(git -C "${source_current}" rev-parse HEAD)"
[ -n "${commit_sha}" ] || { echo "[error] Could not resolve source commit." >&2; exit 1; }

echo "[releasepanel] Promoting ${site_slug}/${from_env} -> ${to_env}"
echo "[releasepanel] Commit: ${commit_sha}"

RELEASEPANEL_DEPLOY_ENV="${target_config}" RELEASEPANEL_DEPLOY_COMMIT_SHA="${commit_sha}" exec "${RELEASEPANEL_TOOLKIT_DIR}/scripts/deploy.sh" "${site_slug}-${to_env}"
