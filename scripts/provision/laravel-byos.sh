#!/usr/bin/env bash
#
# Laravel BYOS "Prepare server" — customer VPS only. Single source of truth (releasepanel-runner).
# The panel reads this file from the runner checkout on the control plane and sends it as the agent provision payload.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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

# Minimal / odd mirrors: universe may be missing from indexes (PHP / composer).
ensure_universe_enabled() {
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

  apt-get update -y
}

echo "[provision] Updating apt indexes ..."
strip_ondrej_launchpad_sources
apt-get update -y

echo "[provision] Installing base packages..."
apt-get install -y --no-install-recommends \
  nginx git unzip curl ca-certificates apt-transport-https software-properties-common

echo "[provision] Installing PHP (native noble packages)..."
strip_ondrej_launchpad_sources || true
apt-get update -y
php_candidate=""
php_candidate=$(apt-cache policy php8.3-cli 2>/dev/null | awk '/^  Candidate:/ {print $2; exit}')
if [[ -z "${php_candidate}" || "${php_candidate}" == "(none)" ]]; then
  ensure_universe_enabled
fi

echo "[provision] Installing PHP 8.3, extensions, and distro composer..."
apt-get install -y --no-install-recommends \
  php8.3 php8.3-fpm php8.3-cli \
  php8.3-mysql php8.3-curl php8.3-xml \
  php8.3-mbstring php8.3-zip php8.3-bcmath php8.3-intl php8.3-gd \
  composer

if id -u deploy >/dev/null 2>&1; then
  echo "[provision] User deploy already exists."
else
  echo "[provision] Creating deploy user..."
  useradd -m -s /bin/bash deploy
fi

echo "[provision] Setting composer cache for deploy user..."
install -d -m 0755 -o deploy -g deploy /home/deploy/.composer 2>/dev/null || true
chown -R deploy:deploy /home/deploy/.composer 2>/dev/null || true

echo "[provision] Preparing /var/www ..."
mkdir -p /var/www
chown deploy:deploy /var/www || true

echo "[provision] Configuring nginx default site..."
rm -f /etc/nginx/sites-enabled/default || true

echo "[provision] Enabling nginx + php8.3-fpm ..."
systemctl daemon-reexec 2>/dev/null || true
systemctl enable --now nginx 2>/dev/null || true
systemctl enable --now php8.3-fpm 2>/dev/null || true
systemctl restart php8.3-fpm 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true

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
