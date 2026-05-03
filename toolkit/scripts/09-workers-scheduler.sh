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
: "${RELEASEPANEL_WORKER_MODE:=queue}"

log "Installing supervisor worker configs."

case "${RELEASEPANEL_SITE_SLUG}" in
    releasepanel-app)
        worker_configs=(
            "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-panel-default.conf"
            "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-panel-deployments.conf"
            "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-panel-runners.conf"
            "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-panel-maintenance.conf"
        )
        ;;
    *)
        case "${RELEASEPANEL_WORKER_MODE}" in
            queue)
                worker_configs=(
                    "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-default.conf"
                    "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-heavy.conf"
                    "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-notifications.conf"
                )
                ;;
            horizon)
                worker_configs=(
                    "${RELEASEPANEL_TOOLKIT_DIR}/supervisor/releasepanel-horizon.conf"
                )
                ;;
            *)
                fail "Unsupported RELEASEPANEL_WORKER_MODE=${RELEASEPANEL_WORKER_MODE}. Use queue or horizon."
                ;;
        esac
        ;;
esac

for program in default heavy notifications horizon deployments runners maintenance; do
    rm -f "/etc/supervisor/conf.d/releasepanel-${RELEASEPANEL_ENV}-${program}.conf"
done

for file in "${worker_configs[@]}"; do
    name="$(basename "${file}")"
    env_name="${name/releasepanel-/releasepanel-${RELEASEPANEL_ENV}-}"
    sed \
        -e "s#\\[program:releasepanel-#[program:releasepanel-${RELEASEPANEL_ENV}-#g" \
        -e "s#__RELEASEPANEL_PROGRAM_PREFIX__#${RELEASEPANEL_PROGRAM_PREFIX}#g" \
        -e "s#__RELEASEPANEL_BASE__#${RELEASEPANEL_BASE}#g" \
        -e "s#__RELEASEPANEL_APP_USER__#${RELEASEPANEL_APP_USER}#g" \
        "${file}" > "/etc/supervisor/conf.d/${env_name}"
done

supervisorctl reread
supervisorctl update
if [ "${RELEASEPANEL_SITE_SLUG}" = "releasepanel-app" ]; then
    supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-default:*" || true
    supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-deployments:*" || true
    supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-runners:*" || true
    supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-maintenance:*" || true
else
    case "${RELEASEPANEL_WORKER_MODE}" in
        queue)
            supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-default:*" || true
            supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-heavy:*" || true
            supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-notifications:*" || true
            ;;
        horizon)
            supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-horizon:*" || true
            supervisorctl start "${RELEASEPANEL_PROGRAM_PREFIX}-horizon" || true
            ;;
    esac
fi
restart_workers

log "Installing scheduler cron."
cat > "/etc/cron.d/releasepanel-${RELEASEPANEL_ENV}-scheduler" <<EOF
* * * * * ${RELEASEPANEL_APP_USER} cd ${RELEASEPANEL_BASE}/current && php artisan schedule:run >> /dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/releasepanel-${RELEASEPANEL_ENV}-scheduler"

log "Workers and scheduler installed for ${RELEASEPANEL_ENV} (site=${RELEASEPANEL_SITE_SLUG}, mode=${RELEASEPANEL_WORKER_MODE})."
