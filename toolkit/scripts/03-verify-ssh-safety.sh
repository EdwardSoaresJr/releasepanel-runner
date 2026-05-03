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

log "Checking SSH safety before hardening."

sshd_config="/etc/ssh/sshd_config"
authorized_keys="/root/.ssh/authorized_keys"

root_permit="$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}' || true)"
password_auth="$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}' || true)"

log "Current PermitRootLogin: ${root_permit:-unknown}"
log "Current PasswordAuthentication: ${password_auth:-unknown}"

if [ ! -s "${authorized_keys}" ]; then
    fail "No root SSH public key found at ${authorized_keys}. Do not harden SSH."
fi

key_count="$(grep -cE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)' "${authorized_keys}" || true)"
[ "${key_count}" -gt 0 ] || fail "No valid public keys found in ${authorized_keys}."

cat <<'TEXT'

STOP BEFORE HARDENING:
1. Open a SECOND terminal.
2. SSH into this server as root using your SSH key.
3. Confirm it logs in without a password.
4. Only then type YES below.

This script never hardens SSH automatically during bootstrap.
TEXT

if ! confirm "Have you verified root SSH key login in a second terminal?"; then
    fail "SSH hardening aborted."
fi

warn "Ready for hardening. Run scripts/11-security-hardening.sh when you intentionally want to disable password auth."
log "No SSH settings were changed by this verification script."
