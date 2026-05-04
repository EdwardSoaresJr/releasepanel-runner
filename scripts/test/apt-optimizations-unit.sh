#!/usr/bin/env bash
# Safe, hermetic checks (no real apt-get update / no rewriting system /etc).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/apt-optimizations.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

TMP=""
cleanup() {
  [[ -n "${TMP}" ]] && rm -rf "${TMP}"
}
trap cleanup EXIT

TMP="$(mktemp -d)"

#
# Classic sources.list rewrite (same sed style as _rp_apt_apply_mirror_one_file)
#
SL="${TMP}/sources.list"
_mirror='http://mirrors.digitalocean.com/ubuntu'
printf '%s\n' \
  'deb http://archive.ubuntu.com/ubuntu noble main' \
  'deb https://security.ubuntu.com/ubuntu noble-security main' \
  >"${SL}"

sed -E \
  -e "s|https?://archive\\.ubuntu\\.com/ubuntu|${_mirror}|g" \
  -e "s|https?://security\\.ubuntu\\.com/ubuntu|${_mirror}|g" \
  -e "s|https?://[a-zA-Z0-9.-]+\\.clouds\\.archive\\.ubuntu\\.com/ubuntu|${_mirror}|g" \
  "${SL}" >"${SL}.out" && mv "${SL}.out" "${SL}"

grep -Fq 'deb http://mirrors.digitalocean.com/ubuntu noble main' "${SL}" || fail 'archive line rewrite'
grep -Fq 'deb http://mirrors.digitalocean.com/ubuntu noble-security main' "${SL}" || fail 'security line rewrite'

#
# deb822 .sources + clouds host
#
DEB="${TMP}/ubuntu.sources"
printf '%s\n' \
  'Types: deb' \
  'URIs: http://nova.clouds.archive.ubuntu.com/ubuntu' \
  'Suites: noble' \
  'Components: main' \
  >"${DEB}"

sed -E \
  -e "s|https?://archive\\.ubuntu\\.com/ubuntu|${_mirror}|g" \
  -e "s|https?://security\\.ubuntu\\.com/ubuntu|${_mirror}|g" \
  -e "s|https?://[a-zA-Z0-9.-]+\\.clouds\\.archive\\.ubuntu\\.com/ubuntu|${_mirror}|g" \
  "${DEB}" >"${DEB}.out" && mv "${DEB}.out" "${DEB}"

grep -Fq "URIs: ${_mirror}" "${DEB}" || fail 'deb822 clouds URIs rewrite'

#
# releasepanel_base_image_ready: requires composer (no system PATH pollution)
#
STUB="${TMP}/stub"
mkdir -p "${STUB}"
stub() {
  printf '#!/bin/bash\nexit 0\n' >"${STUB}/$1"
  chmod +x "${STUB}/$1"
}
for b in nginx php git curl php8.3; do stub "${b}"; done
# systemctl prints a line that matches list-unit-files expectation
cat >"${STUB}/systemctl" <<'EOS'
#!/bin/bash
if [[ "$1" == "list-unit-files" ]]; then
  echo "php8.3-fpm.service                enabled         enabled"
fi
exit 0
EOS
chmod +x "${STUB}/systemctl"

PATH="${STUB}:/usr/bin:/bin:/usr/sbin" command -v nginx >/dev/null 2>&1 || true
if PATH="${STUB}:/usr/bin:/bin:/usr/sbin" releasepanel_base_image_ready; then
  fail 'expected missing composer to fail readiness'
fi

stub composer

PATH="${STUB}:/usr/bin:/bin:/usr/sbin" releasepanel_base_image_ready || fail 'expected readiness with full stubs'

#
# apt_update_safe: succeed after transient failures (mock apt-get + no-op retries)
#
MOCKAPT="${TMP}/aptbin"
mkdir -p "${MOCKAPT}"
APT_TRY="${TMP}/apt_try_counter"
rm -f "${APT_TRY}"
cat >"${MOCKAPT}/apt-get" <<'EOS'
#!/bin/bash
set -euo pipefail
[[ "$1" == "update" ]] || exit 99
f="${APT_TRY_STATE:?}"
n=1
[[ -f "${f}" ]] && n=$(( $(cat "${f}") + 1 ))
echo "${n}" >"${f}"
[[ "${n}" -ge 2 ]] && exit 0
exit 1
EOS
chmod +x "${MOCKAPT}/apt-get"
export APT_TRY_STATE="${APT_TRY}"

bash <<EOS2 || fail 'apt_update_safe should recover'
set -euo pipefail
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/apt-optimizations.sh"
apply_detected_mirror() { return 0; }
clean_apt_cache_safe() { return 0; }
sleep() { return 0; }
export PATH="${MOCKAPT}:/usr/bin:/bin"
apt_update_safe
EOS2
unset APT_TRY_STATE

#
# apt_update_safe: non-zero after 3 failures
#
cat >"${MOCKAPT}/apt-get" <<'EOS'
#!/bin/bash
[[ "$1" == "update" ]] || exit 99
exit 1
EOS
chmod +x "${MOCKAPT}/apt-get"

export ROOT MOCKAPT
set +e
bash <<'EOS3'
set -euo pipefail
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/apt-optimizations.sh"
apply_detected_mirror() { return 0; }
clean_apt_cache_safe() { return 0; }
sleep() { return 0; }
export PATH="${MOCKAPT}:/usr/bin:/bin"
apt_update_safe
EOS3
ev=$?
set -e
[[ "${ev}" -eq 0 ]] && fail 'expected apt_update_safe to fail after 3 attempts'

echo 'OK: apt-optimizations unit checks passed'
exit 0
