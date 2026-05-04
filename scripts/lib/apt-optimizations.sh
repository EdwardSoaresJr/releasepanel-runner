#!/usr/bin/env bash
# Shared apt tuning for ReleasePanel runner install + BYOS provisioning (sourced).
# IPv4-first, short probes (<=2s) to pick archive.ubuntu.com vs mirrors.digitalocean.com,
# timeout drop-ins, cache clean, and self-healing apt-update wrapper.

_rp_apt_ubuntu_codename() {
  local c=""
  if [[ -f /etc/os-release ]]; then
    # VERSION_CODENAME may already be set by the caller after sourcing os-release.
    if [[ -n "${VERSION_CODENAME:-}" ]]; then
      c="${VERSION_CODENAME}"
    else
      # shellcheck disable=SC1091
      c="$(source /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
    fi
  fi
  [[ -n "${c}" ]] || c="noble"
  printf '%s' "${c}"
}

# Logs to stderr only; emits mirror hostname on stdout (no extra output).
detect_fast_apt_mirror() {
  echo "[apt] detecting fast mirror..." >&2
  local timeout=2
  local codename
  codename="$(_rp_apt_ubuntu_codename)"
  local default_url="http://archive.ubuntu.com/ubuntu/dists/${codename}/InRelease"
  local do_url="http://mirrors.digitalocean.com/ubuntu/dists/${codename}/InRelease"

  if ! command -v curl >/dev/null 2>&1; then
    echo "[apt] curl unavailable — using default mirror" >&2
    printf '%s' archive.ubuntu.com
    return 0
  fi

  if curl -fsS -m "${timeout}" --head -o /dev/null "${default_url}" 2>/dev/null; then
    echo "[apt] default mirror responsive" >&2
    printf '%s' archive.ubuntu.com
    return 0
  fi

  echo "[apt] default mirror slow/unreachable — trying DO mirror..." >&2
  if curl -fsS -m "${timeout}" --head -o /dev/null "${do_url}" 2>/dev/null; then
    echo "[apt] using DigitalOcean mirror" >&2
    printf '%s' mirrors.digitalocean.com
    return 0
  fi

  echo "[apt] fallback to default mirror" >&2
  printf '%s' archive.ubuntu.com
}

apply_detected_mirror() {
  [[ -f /etc/os-release ]] || return 0
  grep -qi ubuntu /etc/os-release 2>/dev/null || return 0

  local mirror
  mirror="$(detect_fast_apt_mirror)"
  mirror="$(printf '%s' "${mirror}" | tr -d '[:space:]')"
  [[ -n "${mirror}" ]] || mirror="archive.ubuntu.com"

  echo "[apt] applying mirror: ${mirror}"

  if [[ -f /etc/apt/sources.list ]]; then
    sed -i "s|archive\\.ubuntu\\.com|${mirror}|g; s|security\\.ubuntu\\.com|${mirror}|g" /etc/apt/sources.list
  fi

  local f=""
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "${f}" ]] || continue
    if grep -qE '(archive|security)\.ubuntu\.com' "${f}" 2>/dev/null; then
      sed -i "s|archive\\.ubuntu\\.com|${mirror}|g; s|security\\.ubuntu\\.com|${mirror}|g" "${f}"
    fi
  done
  for f in /etc/apt/sources.list.d/ubuntu*.list /etc/apt/sources.list.d/*ubuntu*.list; do
    [[ -f "${f}" ]] || continue
    if grep -qE '(archive|security)\.ubuntu\.com' "${f}" 2>/dev/null; then
      sed -i "s|archive\\.ubuntu\\.com|${mirror}|g; s|security\\.ubuntu\\.com|${mirror}|g" "${f}"
    fi
  done
  shopt -u nullglob
}

ensure_apt_acquire_timeouts() {
  install -d -m 0755 /etc/apt/apt.conf.d
  cat >/etc/apt/apt.conf.d/99timeouts <<'EOF'
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Retries "3";
EOF
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

apt_update_safe() {
  echo "[apt] updating (safe mode)..."
  local attempt
  for attempt in 1 2 3; do
    if apt-get update -y; then
      if [[ "${attempt}" -gt 1 ]] && [[ -n "${APT_UPDATE_SAFE_LOG_PROVISION:-}" ]]; then
        echo "[provision] apt recovered after ${attempt} attempts"
      fi
      return 0
    fi

    if [[ "${attempt}" -eq 3 ]]; then
      break
    fi

    echo "[apt] update failed, retrying with mirror re-detect..."
    apply_detected_mirror || true
    clean_apt_cache_safe || true
    sleep 3
  done
  if [[ -n "${APT_UPDATE_SAFE_LOG_PROVISION:-}" ]]; then
    echo "[provision] ERROR: apt-get update failed after 3 attempts." >&2
  else
    echo "[apt] ERROR: apt-get update failed after 3 attempts." >&2
  fi
  return 1
}

# Deprecated alias (older callers); uses probe-based mirrors for all hosts.
force_fast_apt_mirrors() {
  apply_detected_mirror
}
