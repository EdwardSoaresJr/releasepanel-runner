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

authorized_keys="/root/.ssh/authorized_keys"
[ -s "${authorized_keys}" ] || fail "No root authorized_keys file. Refusing to harden SSH."

cat <<'TEXT'

SSH HARDENING WARNING

Before continuing:
1. Open a second terminal.
2. SSH as root using your SSH key.
3. Confirm you can log in without a password.

This will disable SSH password auth and prevent password-based root login.
TEXT

if ! confirm "I verified SSH key login in a second terminal"; then
    fail "Hardening aborted."
fi

cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

cat > /etc/ssh/sshd_config.d/99-releasepanel-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF

sshd -t
systemctl reload ssh || systemctl reload sshd

ufw --force enable
systemctl enable --now fail2ban

log "Security hardening applied."
