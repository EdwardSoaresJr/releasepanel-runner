#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=site-runner-common.sh
. "${SCRIPT_DIR}/site-runner-common.sh"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_site_env_args "$@"
set -- "${SITE_ENV_NAME}"
parse_deploy_env_as_first_arg "${1}"
shift
load_env

echo "Fixed log targets for ${RELEASEPANEL_SITE_SLUG}/${RELEASEPANEL_ENV_SLUG}:"
echo "deploy=/var/log/releasepanel-${RELEASEPANEL_ENV}-deploy.log"
echo "nginx_access=/var/log/nginx/${RELEASEPANEL_NGINX_SITE_BASENAME}-access.log"
echo "nginx_error=/var/log/nginx/${RELEASEPANEL_NGINX_SITE_BASENAME}-error.log"
echo "laravel=${RELEASEPANEL_SHARED}/storage/logs/laravel.log"
echo "runner=/var/log/managed-deploy-agent.log"
