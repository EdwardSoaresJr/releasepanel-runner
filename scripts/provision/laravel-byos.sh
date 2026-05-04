#!/usr/bin/env bash
#
# Laravel BYOS "Prepare server" — customer VPS only. Single source of truth (releasepanel-runner).
# The panel reads this file from the runner checkout on the control plane and sends it as the agent provision payload.
#
set -euo pipefail
if [[ "${RELEASEPANEL_PROVISION_DEBUG:-0}" == "1" ]]; then
  set -x
fi
trap 'status=$?; echo "[provision] FAILED at line ${LINENO} (exit ${status}): ${BASH_COMMAND}" >&2' ERR

export DEBIAN_FRONTEND=noninteractive

echo "[provision] Validating operating system..."
if [[ ! -f /etc/os-release ]]; then
  echo "Missing /etc/os-release — unsupported OS." >&2
  exit 1
fi
if ! grep -qiE 'ubuntu' /etc/os-release 2>/dev/null; then
  echo "Unsupported OS — BYOS provision requires Ubuntu 24.04 LTS (noble) or newer (check /etc/os-release)." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
  echo "Unsupported OS — BYOS provision requires Ubuntu (noble). Found ID=${ID}." >&2
  exit 1
fi

UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
if [[ ! "${UBUNTU_CODENAME}" =~ ^(noble|oracular|questing)$ ]]; then
  echo "[provision] BYOS provision targets Ubuntu 24.04 LTS (noble). This release is: ${UBUNTU_CODENAME:-unknown}. Use a noble (or newer Ubuntu LTS) image." >&2
  exit 1
fi

# Shared apt optimizations (scripts/lib): IPv4, timeouts, mirror probe, safe apt update.
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/apt-optimizations.sh"
if [[ -f "${_lib}" ]]; then
  # shellcheck source=/dev/null
  source "${_lib}"
fi
command -v force_ipv4_apt >/dev/null 2>&1 || {
  echo "[provision][warn] Missing scripts/lib/apt-optimizations.sh (expected ${_lib}); continuing with distro defaults." >&2
}

strip_ondrej_launchpad_sources() {
  # PPA list files only; safe before software-properties-common is installed.
  # Include *.sources (deb822) and common Launchpad path spellings — do not call
  # add-apt-repository -r here: it still hits Launchpad and prints pages of text.
  local f
  shopt -s nullglob
  for f in \
    /etc/apt/sources.list.d/*ondrej* \
    /etc/apt/sources.list.d/*launchpadcontent_net_ondrej* \
    /etc/apt/sources.list.d/*ppa.launchpadcontent.net_ondrej*; do
    echo "[provision] Removing stale apt source (Launchpad / Ondřej): ${f}"
    rm -f "${f}"
  done
  shopt -u nullglob
}

# Optional: use http:// for official Ubuntu archive URLs to reduce TLS CPU on small VPS.
use_http_for_ubuntu_archive_urls() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu-server.sources; do
    [[ -f "${f}" ]] || continue
    if grep -q 'https://' "${f}"; then
      echo "[provision] Switching Ubuntu archive URLs to http:// in ${f} (optional, low-resource tuning) ..."
      sed -i 's|https://|http://|g' "${f}"
    fi
  done
}

# Minimal / odd mirrors: universe may be missing from indexes (PHP / composer).
# Sets UNIVERSE_SOURCES_MODIFIED=1 when sources were changed; does not run apt-get update.
ensure_universe_enabled() {
  UNIVERSE_SOURCES_MODIFIED=0

  if grep -RqE '^[^#].*universe' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    return 0
  fi
  # deb822 *.sources (common on noble): Components line without universe
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "${f}" ]] || continue
    if grep -qE '^Components:' "${f}" && grep -qE '^Components:.*\buniverse\b' "${f}"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  echo "[provision] Ensuring 'universe' component is enabled ..."
  add-apt-repository universe -y 2>/dev/null || \
    sed -i 's/^# deb \(.*\) universe/deb \1 universe/' /etc/apt/sources.list 2>/dev/null || true

  # Noble deb822: append universe to Components when only main/restricted are listed
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "${f}" ]] || continue
    if grep -qE '^Components:' "${f}" && ! grep -qE '^Components:.*\buniverse\b' "${f}"; then
      sed -i 's/^\(Components:.*\)$/\1 universe/' "${f}" 2>/dev/null || true
    fi
  done
  shopt -u nullglob

  UNIVERSE_SOURCES_MODIFIED=1
}

echo "[provision] Preparing apt sources..."
strip_ondrej_launchpad_sources
use_http_for_ubuntu_archive_urls

echo "[provision] Tuning apt..."
force_ipv4_apt || true
configure_apt_timeouts || true
apply_detected_mirror || true

if releasepanel_base_image_ready; then
  echo "[provision] ReleasePanel base image detected — skipping package installation."
else
  echo "[provision] Updating apt indexes..."
  clean_apt_cache_safe || true
  apt_update_safe

  php_candidate=""
  php_candidate=$(apt-cache policy php8.3-cli 2>/dev/null | awk '/^  Candidate:/ {print $2; exit}')
  if [[ -z "${php_candidate}" || "${php_candidate}" == "(none)" ]]; then
    ensure_universe_enabled
    if [[ "${UNIVERSE_SOURCES_MODIFIED}" -eq 1 ]]; then
      echo "[provision] Refreshing apt indexes after enabling universe ..."
      apt_update_safe
    fi
  fi

  pkgs=(
    git unzip curl ca-certificates apt-transport-https software-properties-common
  )
  if ! command -v nginx >/dev/null 2>&1; then
    pkgs+=(nginx)
  else
    echo "[provision] nginx already present — skipping nginx package in apt install."
  fi

  if ! command -v php >/dev/null 2>&1; then
    pkgs+=(
      php8.3 php8.3-fpm php8.3-cli
      php8.3-mysql php8.3-curl php8.3-xml
      php8.3-mbstring php8.3-zip php8.3-bcmath php8.3-intl php8.3-gd
    )
  else
    echo "[provision] php already present — skipping PHP packages in apt install."
  fi

  if ! command -v composer >/dev/null 2>&1; then
    pkgs+=(composer)
  fi

  echo "[provision] Installing packages..."
  apt_prefetch_packages "${pkgs[@]}"
  apt_install_packages "${pkgs[@]}"
  releasepanel_write_base_image_marker || true
fi

echo "[provision] Creating deploy user..."
if id -u deploy >/dev/null 2>&1; then
  echo "[provision] User deploy already exists."
else
  useradd -m -s /bin/bash deploy
fi

echo "[provision] Setting composer cache for deploy user..."
install -d -m 0755 -o deploy -g deploy /home/deploy/.composer 2>/dev/null || true
chown -R deploy:deploy /home/deploy/.composer 2>/dev/null || true

echo "[provision] Preparing /var/www ..."
mkdir -p /var/www
chown deploy:deploy /var/www || true

echo "[provision] Configuring services..."
echo "[provision] Configuring nginx default site..."
rm -f /etc/nginx/sites-enabled/default || true

echo "[provision] Enabling nginx + php8.3-fpm ..."
systemctl daemon-reexec 2>/dev/null || true
systemctl enable --now nginx php8.3-fpm 2>/dev/null || true

if nginx -t 2>/dev/null; then
  systemctl reload nginx 2>/dev/null || true
else
  echo "[provision][warn] nginx -t failed — fix config before relying on nginx." >&2
fi

echo "[provision] Verifying PHP-FPM..."
systemctl is-active --quiet php8.3-fpm || echo "[provision][warn] php8.3-fpm not active"

echo "[provision] Verifying nginx..."
systemctl is-active --quiet nginx || echo "[provision][warn] nginx not active"

php -v 2>/dev/null || echo "[provision][warn] php CLI not responding"

echo "[provision] Complete."
