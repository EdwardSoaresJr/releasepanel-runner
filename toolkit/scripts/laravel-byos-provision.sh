#!/usr/bin/env bash
#
# Canonical Laravel BYOS "Prepare server" script (customer VPS only).
# ReleasePanel panel queues this file's contents as the provision agent job payload.
# Source of truth: releasepanel-runner — do not duplicate in the panel repo except as an emergency fallback.
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

echo "[provision] Updating apt indexes ..."
strip_ondrej_launchpad_sources
apt-get update -y

echo "[provision] Installing base packages..."
apt-get install -y nginx git unzip curl ca-certificates apt-transport-https software-properties-common

echo "[provision] Installing PHP (native noble packages)..."
strip_ondrej_launchpad_sources || true
apt-get update -y
php_candidate=""
php_candidate=$(apt-cache policy php8.3-cli 2>/dev/null | awk '/^  Candidate:/ {print $2; exit}')
if [[ -z "${php_candidate}" || "${php_candidate}" == "(none)" ]]; then
  echo "[provision] Enabling universe component (PHP / Composer live in universe on minimal cloud images) ..."
  add-apt-repository universe -y 2>/dev/null || true
  apt-get update -y
fi

echo "[provision] Installing PHP 8.3, extensions, and distro composer..."
apt-get install -y \
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

echo "[provision] Preparing /var/www ..."
mkdir -p /var/www
chown deploy:deploy /var/www || true

echo "[provision] Enabling nginx + php8.3-fpm ..."
systemctl enable nginx 2>/dev/null || true
systemctl enable php8.3-fpm 2>/dev/null || true
systemctl restart php8.3-fpm || true
systemctl restart nginx || true

echo "[provision] Complete."
