#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root
if ! parse_deploy_env_as_first_arg "${1:-}"; then
    fail "Usage: ${0##*/} <site-env>"
fi
shift
load_env

id "${RELEASEPANEL_APP_USER}" >/dev/null 2>&1 || fail "User ${RELEASEPANEL_APP_USER} does not exist. Run 02-create-app-user.sh ${RELEASEPANEL_ENV} first."

key_dir="/root/.ssh/releasepanel"
key_path="${key_dir}/${RELEASEPANEL_SITE_SLUG}_${RELEASEPANEL_ENV_SLUG}"
config_file="${RELEASEPANEL_DEPLOY_ENV}"

log "Creating GitHub deploy key for ${RELEASEPANEL_SITE_SLUG}/${RELEASEPANEL_ENV_SLUG}."

install -d -m 0700 "${key_dir}"

if [ ! -f "${key_path}" ]; then
    ssh-keygen -t ed25519 -C "releasepanel-${RELEASEPANEL_SITE_SLUG}-${RELEASEPANEL_ENV_SLUG}@$(hostname -f 2>/dev/null || hostname)" -f "${key_path}" -N ""
fi

chmod 600 "${key_path}"
chmod 644 "${key_path}.pub"

if grep -q '^RELEASEPANEL_SSH_IDENTITY_FILE=' "${config_file}"; then
    sed -i -E "s#^RELEASEPANEL_SSH_IDENTITY_FILE=.*#RELEASEPANEL_SSH_IDENTITY_FILE=\"${key_path}\"#" "${config_file}"
else
    printf 'RELEASEPANEL_SSH_IDENTITY_FILE=\"%s\"\n' "${key_path}" >> "${config_file}"
fi

echo
echo "Add this public key to GitHub:"
echo "Repo -> Settings -> Deploy keys -> Add deploy key -> Allow read access"
echo
cat "${key_path}.pub"
echo

if ! confirm "Have you added this key to the ReleasePanel GitHub repo deploy keys?"; then
    fail "Add the deploy key in GitHub, then rerun this script."
fi

log "Testing GitHub SSH authentication."
ssh_output="$(GIT_SSH_COMMAND="ssh -i ${key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" ssh -T git@github.com 2>&1 || true)"

if echo "${ssh_output}" | grep -qi "successfully authenticated"; then
    echo "[ok] GitHub SSH auth verified."
elif echo "${ssh_output}" | grep -qi "Hi "; then
    echo "[ok] GitHub SSH auth verified."
else
    echo "${ssh_output}"
    fail "GitHub SSH auth failed. Confirm the deploy key is attached to the correct repo."
fi

log "GitHub deploy key is ready."
