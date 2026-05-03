#!/usr/bin/env bash
set -Eeuo pipefail

RELEASEPANEL_TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=site-runner-common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-runner-common.sh"

load_site_env_args "$@"

bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/06-nginx-phase1.sh" "${SITE_ENV_NAME}"
bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/07-certbot-ssl.sh" "${SITE_ENV_NAME}"
exec bash "${RELEASEPANEL_TOOLKIT_DIR}/scripts/08-nginx-final.sh" "${SITE_ENV_NAME}"
