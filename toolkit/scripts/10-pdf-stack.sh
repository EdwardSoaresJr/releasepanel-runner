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

log "Installing PDF stack dependencies."
apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    wkhtmltopdf xvfb fontconfig fonts-dejavu fonts-liberation fonts-noto-core \
    libxrender1 libxext6 libfontconfig1 libjpeg-turbo8 libpng16-16

if [ -x "${RELEASEPANEL_CURRENT}/vendor/h4cc/wkhtmltopdf-amd64/bin/wkhtmltopdf-amd64" ]; then
    log "Found h4cc wkhtmltopdf binary."
    runuser -s /bin/bash www-data -c "${RELEASEPANEL_CURRENT}/vendor/h4cc/wkhtmltopdf-amd64/bin/wkhtmltopdf-amd64 --version"
else
    warn "h4cc wkhtmltopdf binary not found in current release; using system wkhtmltopdf."
fi

runuser -s /bin/bash www-data -c "wkhtmltopdf --version"

tmp_html="$(mktemp /tmp/releasepanel-pdf-smoke.XXXXXX.html)"
tmp_pdf="$(mktemp /tmp/releasepanel-pdf-smoke.XXXXXX.pdf)"
echo '<html><body><h1>ReleasePanel PDF smoke</h1></body></html>' > "${tmp_html}"
chown www-data:www-data "${tmp_html}" "${tmp_pdf}"
runuser -s /bin/bash www-data -c "wkhtmltopdf ${tmp_html} ${tmp_pdf}"
[ -s "${tmp_pdf}" ] || fail "wkhtmltopdf smoke test did not create a PDF."
rm -f "${tmp_html}" "${tmp_pdf}"

log "PDF stack verified."
