#!/usr/bin/env bash
set -Eeuo pipefail

RELEASEPANEL_TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=site-runner-common.sh
. "${RELEASEPANEL_TOOLKIT_DIR}/scripts/site-runner-common.sh"

load_site_env_args "$@"

exec "${RELEASEPANEL_TOOLKIT_DIR}/scripts/09-workers-scheduler.sh" "${SITE_ENV_NAME}"
