#!/usr/bin/env bash
set -Eeuo pipefail

RELEASEPANEL_TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=site-runner-common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-runner-common.sh"

load_site_env_args "$@"

"${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-nginx.sh" "${SITE_SLUG}" "${ENV_SLUG}"
"${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-workers.sh" "${SITE_SLUG}" "${ENV_SLUG}"
exec bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-smoke.sh" "${SITE_SLUG}" "${ENV_SLUG}"
