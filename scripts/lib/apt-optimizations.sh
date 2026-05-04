#!/usr/bin/env bash
# Shared apt tuning for ReleasePanel runner install + BYOS provisioning.
# Intended to be sourced (not executed). Uses short apt timeouts / IPv4 everywhere;
# rewrites Ubuntu mirrors to DigitalOcean only when confidently on DO Ubuntu.

_rp_apt_is_ubuntu_os() {
  [[ -f /etc/os-release ]] && grep -qi ubuntu /etc/os-release 2>/dev/null
}

_rp_apt_is_digitalocean_context() {
  local h=""
  if h="$(hostname 2>/dev/null)" && echo "${h}" | grep -qi digitalocean; then
    return 0
  fi
  if [[ -f /etc/motd ]] && grep -qi digitalocean /etc/motd 2>/dev/null; then
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    local id=""
    id="$(curl -fsS --connect-timeout 1 --max-time 2 "http://169.254.169.254/metadata/v1/id" 2>/dev/null || true)"
    id="$(printf '%s' "${id}" | tr -cd '[:alnum:]')"
    [[ -n "${id}" ]] && return 0
  fi
  return 1
}

_rp_apt_apply_do_mirrors() {
  local f=""
  # Classic one-line sources.list (older images)
  if [[ -f /etc/apt/sources.list ]] && grep -qE '(archive|security)\.ubuntu\.com' /etc/apt/sources.list 2>/dev/null; then
    sed -i 's|archive\.ubuntu\.com|mirrors.digitalocean.com|g; s|security\.ubuntu\.com|mirrors.digitalocean.com|g' /etc/apt/sources.list
  fi
  # deb822 (*.sources): Ubuntu 24+
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "${f}" ]] || continue
    if grep -qE '(archive|security)\.ubuntu\.com' "${f}" 2>/dev/null; then
      sed -i 's|archive\.ubuntu\.com|mirrors.digitalocean.com|g; s|security\.ubuntu\.com|mirrors.digitalocean.com|g' "${f}"
    fi
  done
  shopt -u nullglob
  # Older .list snippets
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/ubuntu*.list /etc/apt/sources.list.d/*ubuntu*.list; do
    [[ -f "${f}" ]] || continue
    if grep -qE '(archive|security)\.ubuntu\.com' "${f}" 2>/dev/null; then
      sed -i 's|archive\.ubuntu\.com|mirrors.digitalocean.com|g; s|security\.ubuntu\.com|mirrors.digitalocean.com|g' "${f}"
    fi
  done
  shopt -u nullglob
}

# Apply DigitalOcean Ubuntu mirrors only on Ubuntu hosts that appear to run on DigitalOcean.
force_fast_apt_mirrors() {
  _rp_apt_is_ubuntu_os || return 0
  if ! _rp_apt_is_digitalocean_context; then
    return 0
  fi
  echo "[apt] enforcing fast mirrors"
  _rp_apt_apply_do_mirrors
}

force_ipv4_apt() {
  echo "[apt] forcing IPv4"
  install -d -m 0755 /etc/apt/apt.conf.d
  cat >/etc/apt/apt.conf.d/99releasepanel-optimizations <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Queue-Mode "host";
APT::Install-Recommends "0";
APT::Install-Suggests "0";
DPkg::Use-Pty "0";
DPkg::Options { "--force-confdef"; "--force-confold"; };
EOF
}

clean_apt_cache_safe() {
  echo "[apt] cleaning cache"
  rm -rf /var/lib/apt/lists/*
  apt-get clean 2>/dev/null || true
}
