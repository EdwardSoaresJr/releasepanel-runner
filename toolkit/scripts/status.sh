#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

require_root
if ! parse_deploy_env_as_first_arg "${1:-}"; then
    fail "Usage: ${0##*/} <site-env>"
fi
shift
load_env

stamp="${RELEASEPANEL_SHARED}/deploy.json"
current_link="${RELEASEPANEL_CURRENT}"

echo "Env:             ${RELEASEPANEL_ENV}"
echo "Base:            ${RELEASEPANEL_BASE}"
echo "Server name:     ${RELEASEPANEL_SERVER_NAME:-}"
echo "Branch (config): ${RELEASEPANEL_BRANCH}"

if [ -L "${RELEASEPANEL_BASE}/previous" ]; then
    prev="$(readlink -f "${RELEASEPANEL_BASE}/previous" 2>/dev/null || true)"
    echo "Previous release: ${prev:-broken symlink}"
    if [ -n "${prev}" ] && [ ! -d "${prev}" ]; then
        warn "previous target is not a directory (pruned release or broken symlink)."
    fi
else
    echo "Previous release: (none — created on next deploy after first successful switch)"
fi

if [ -L "${current_link}" ]; then
    cur="$(readlink -f "${current_link}")"
    echo "Current release: ${cur}"
    if [ -d "${cur}/.git" ]; then
        echo "Commit (git):    $(run_as_app_user_in "${cur}" git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "Commit (full):   $(run_as_app_user_in "${cur}" git rev-parse HEAD 2>/dev/null || echo unknown)"
        origin_tip="$(run_as_app_user_in "${cur}" git ls-remote origin "refs/heads/${RELEASEPANEL_BRANCH}" 2>/dev/null | awk '{print substr($1,1,7); exit}' || true)"
        if [ -n "${origin_tip}" ]; then
            echo "Origin ${RELEASEPANEL_BRANCH}: ${origin_tip} (git ls-remote; needs network + remote access)"
        else
            echo "Origin ${RELEASEPANEL_BRANCH}: n/a (ls-remote failed or offline)"
        fi
    fi
else
    echo "Current symlink: (missing)"
fi

if [ -f "${stamp}" ]; then
    echo ""
    echo "--- deploy.json ---"
    sed 's/^/  /' "${stamp}"
else
    echo ""
    echo "deploy.json:     (not found — run a deploy first)"
fi

echo ""
echo "--- nginx ---"
if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
        printf '[ok] nginx config\n'
    else
        printf '[fail] nginx config\n'
    fi
else
    printf '[fail] nginx not installed\n'
fi

echo ""
echo "--- supervisor (${RELEASEPANEL_PROGRAM_PREFIX}) ---"
if command -v supervisorctl >/dev/null 2>&1; then
    sup_out="$(supervisorctl status 2>/dev/null | grep "releasepanel-${RELEASEPANEL_ENV}" || true)"
    if [ -n "${sup_out}" ]; then
        printf '%s\n' "${sup_out}" | sed 's/^/  /'
    else
        echo "  (no matching programs — run: bash scripts/09-workers-scheduler.sh ${RELEASEPANEL_ENV})"
    fi
else
    echo "  supervisorctl not found"
fi

echo ""
echo "--- redis ---"
if command -v redis-cli >/dev/null 2>&1; then
    rp="$(redis-cli ping 2>/dev/null || true)"
    case "${rp}" in
        PONG) echo "  PONG (ok)" ;;
        *)
            warn "Redis not responding (${rp:-no reply}) — queue workers cannot process jobs until Redis is fixed."
            ;;
    esac
else
    echo "  redis-cli not installed"
fi

echo ""
echo "--- queue depth (redis LLEN; adjust keys if you use REDIS_PREFIX) ---"
if command -v redis-cli >/dev/null 2>&1 && [ "$(redis-cli ping 2>/dev/null || true)" = "PONG" ]; then
    for key in queues:default queues:projections queues:mail queues:notifications queues:telephony queues:pdf queues:ai queues:heavy; do
        len="$(redis-cli LLEN "${key}" 2>/dev/null || true)"
        if [ -z "${len}" ]; then
            len="?"
        fi
        echo "  ${key}: ${len}"
    done
else
    echo "  (skipped — Redis unavailable)"
fi
