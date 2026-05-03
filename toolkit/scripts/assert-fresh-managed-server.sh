#!/usr/bin/env bash
set -Eeuo pipefail

# Abort if this machine already has a web stack, unless a prior managed bootstrap completed
# (see 01-bootstrap.sh) or the operator explicitly opts out.

STATE_DIR="${MANAGED_AGENT_STATE_DIR:-/var/lib/managed-deploy-agent}"
MARKER="${STATE_DIR}/bootstrap-runner.completed"

is_truthy() {
    case "${1:-}" in
        1 | true | TRUE | yes | YES | on | ON) return 0 ;;
        *) return 1 ;;
    esac
}

if is_truthy "${MANAGED_AGENT_SKIP_FRESH_SERVER_CHECK:-}" || is_truthy "${RELEASEPANEL_SKIP_FRESH_SERVER_CHECK:-}"; then
    exit 0
fi

if [ -f "${MARKER}" ]; then
    exit 0
fi

# Common preinstalled / manually installed web servers on generic VPS images.
conflicts=(apache2 caddy lighttpd nginx)
found=()

for pkg in "${conflicts[@]}"; do
    if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
        found+=("${pkg}")
    fi
done

if [ "${#found[@]}" -gt 0 ]; then
    echo "[managed-deploy-agent] ERROR: This flow targets a fresh Ubuntu server with no web server stack installed yet." >&2
    echo "[managed-deploy-agent] Already-installed package(s): ${found[*]}" >&2
    echo "[managed-deploy-agent] Use a new VPS, uninstall that stack, or set MANAGED_AGENT_SKIP_FRESH_SERVER_CHECK=1 (advanced / risk of breaking an existing site)." >&2
    exit 1
fi

exit 0
