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

key_dir="/root/.ssh/releasepanel"
key_path="${key_dir}/${RELEASEPANEL_SITE_SLUG}_${RELEASEPANEL_ENV_SLUG}"

install -d -m 0700 "${key_dir}"

if [ ! -f "${key_path}" ]; then
    ssh-keygen -t ed25519 -C "releasepanel-${RELEASEPANEL_SITE_SLUG}-${RELEASEPANEL_ENV_SLUG}@$(hostname -f 2>/dev/null || hostname)" -f "${key_path}" -N "" >/dev/null
fi

chmod 600 "${key_path}"
chmod 644 "${key_path}.pub"

if grep -q '^RELEASEPANEL_SSH_IDENTITY_FILE=' "${RELEASEPANEL_DEPLOY_ENV}"; then
    sed -i -E "s#^RELEASEPANEL_SSH_IDENTITY_FILE=.*#RELEASEPANEL_SSH_IDENTITY_FILE=\"${key_path}\"#" "${RELEASEPANEL_DEPLOY_ENV}"
else
    printf 'RELEASEPANEL_SSH_IDENTITY_FILE="%s"\n' "${key_path}" >> "${RELEASEPANEL_DEPLOY_ENV}"
fi

git_ssh_command="ssh -i ${key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if grep -q '^RELEASEPANEL_GIT_SSH_COMMAND=' "${RELEASEPANEL_DEPLOY_ENV}"; then
    sed -i -E "s#^RELEASEPANEL_GIT_SSH_COMMAND=.*#RELEASEPANEL_GIT_SSH_COMMAND=\"${git_ssh_command}\"#" "${RELEASEPANEL_DEPLOY_ENV}"
else
    printf 'RELEASEPANEL_GIT_SSH_COMMAND="%s"\n' "${git_ssh_command}" >> "${RELEASEPANEL_DEPLOY_ENV}"
fi

echo "Public deploy key for ${RELEASEPANEL_SITE_SLUG}/${RELEASEPANEL_ENV_SLUG}:"
cat "${key_path}.pub"
