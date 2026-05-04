#!/usr/bin/env bash
# Shared apt tuning for ReleasePanel runner install + BYOS provisioning (sourced).
# Safe to call repeatedly: IPv4, performance/timeouts, mirror probe + deb822-aware apply,
# cache clean, self-healing apt update, prefetch/install wrappers, BYOS binary fast-path.

_rp_apt_ubuntu_codename() {
  local c=""
  if [[ -f /etc/os-release ]]; then
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

_rp_apt_runner_git_short() {
  local d=""
  for d in "${RELEASEPANEL_RUNNER_ROOT:-}" "/opt/managed-deploy-agent"; do
    [[ -n "${d}" ]] || continue
    [[ -d "${d}/.git" ]] || continue
    git -C "${d}" rev-parse --short HEAD 2>/dev/null && return 0
  done
  printf 'unknown'
}

# Logs to stderr. Prints mirror BASE URI on stdout only (example: http://mirrors.digitalocean.com/ubuntu).
detect_fast_apt_mirror() {
  echo "[apt] detecting fast mirror" >&2

  local timeout=2
  local codename
  codename="$(_rp_apt_ubuntu_codename)"

  local do_base="http://mirrors.digitalocean.com/ubuntu"
  local ar_base="http://archive.ubuntu.com/ubuntu"

  local selected="${ar_base}"

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS -m "${timeout}" --head -o /dev/null "${do_base}/dists/${codename}/InRelease" 2>/dev/null; then
      selected="${do_base}"
    elif curl -fsS -m "${timeout}" --head -o /dev/null "${ar_base}/dists/${codename}/InRelease" 2>/dev/null; then
      selected="${ar_base}"
    fi
  fi

  echo "[apt] selected mirror: ${selected}" >&2
  printf '%s' "${selected}"
}

_rp_apt_sources_file_is_third_party() {
  local f="${1,,}"
  case "${f}" in
    *nodesource* | *mongodb* | *pgdg* | *yarn* | *docker* | *kubernetes* | *digitalocean* | *droplet* | *do-agent* )
      return 0 ;;
  esac
  return 1
}

_rp_apt_file_needs_mirror_rewrite() {
  local f="$1"
  grep -qiE '(http|https)://archive\.ubuntu\.com/ubuntu|(http|https)://security\.ubuntu\.com/ubuntu|(http|https)://[a-z0-9.-]+\.clouds\.archive\.ubuntu\.com/ubuntu' "${f}" 2>/dev/null
}

_rp_apt_apply_mirror_one_file() {
  local path="$1"
  local mirror_base="$2"

  [[ -f "${path}" ]] || return 0
  [[ -f /etc/os-release ]] && grep -qi ubuntu /etc/os-release 2>/dev/null || return 0

  if _rp_apt_sources_file_is_third_party "${path}"; then
    return 0
  fi

  if ! _rp_apt_file_needs_mirror_rewrite "${path}"; then
    return 0
  fi

  sed -E -i \
    -e "s|https?://archive\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
    -e "s|https?://security\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
    -e "s|https?://[a-zA-Z0-9.-]+\\.clouds\\.archive\\.ubuntu\\.com/ubuntu|${mirror_base}|g" \
    "${path}" 2>/dev/null || true
}

apply_detected_mirror() {
  [[ -f /etc/os-release ]] || return 0
  grep -qi ubuntu /etc/os-release 2>/dev/null || return 0

  local mirror_base=""
  mirror_base="$(detect_fast_apt_mirror)"
  mirror_base="$(printf '%s' "${mirror_base}" | tr -d '\r\n')"
  [[ -n "${mirror_base}" ]] || mirror_base="http://archive.ubuntu.com/ubuntu"

  if [[ -f /etc/apt/sources.list ]]; then
    _rp_apt_apply_mirror_one_file /etc/apt/sources.list "${mirror_base}"
  fi

  local f=""
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    _rp_apt_apply_mirror_one_file "${f}" "${mirror_base}"
  done
  shopt -u nullglob
}

force_ipv4_apt() {
  echo "[apt] forcing IPv4"
  install -d -m 0755 /etc/apt/apt.conf.d
  cat >/etc/apt/apt.conf.d/99releasepanel-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF
}

configure_apt_timeouts() {
  install -d -m 0755 /etc/apt/apt.conf.d
  cat >/etc/apt/apt.conf.d/99releasepanel-apt-performance <<'EOF'
Acquire::Retries "3";
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
  echo "[apt] cleaning apt cache"
  rm -rf /var/lib/apt/lists/*
  apt-get clean 2>/dev/null || true
}

apt_update_safe() {
  local attempt
  for attempt in 1 2 3; do
    echo "[apt] updating indexes"

    if apt-get update -y; then
      if [[ "${attempt}" -gt 1 ]]; then
        echo "[apt] recovered after ${attempt} attempts"
      fi
      return 0
    fi

    if [[ "${attempt}" -eq 3 ]]; then
      echo "[apt] ERROR: apt update failed after 3 attempts" >&2
      return 1
    fi

    echo "[apt] update failed attempt ${attempt}/3"
    apply_detected_mirror || true
    clean_apt_cache_safe || true
    sleep 3
  done
  return 1
}

apt_prefetch_packages() {
  [[ "$#" -eq 0 ]] && return 0
  echo "[apt] prefetching packages"

  local safe=("$@")
  # shellcheck disable=SC2068
  if ! apt-get install --download-only -y --no-install-recommends "${safe[@]}"; then
    echo "[apt] prefetch warning: continuing without warmed cache"
  fi
}

apt_install_packages() {
  [[ "$#" -eq 0 ]] && return 0
  apt-get install -y --no-install-recommends "$@"
}

releasepanel_base_image_ready() {
  command -v nginx >/dev/null 2>&1 || return 1
  command -v php >/dev/null 2>&1 || return 1
  command -v composer >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1

  php8.3 -v >/dev/null 2>&1 || return 1

  if ! systemctl list-unit-files 2>/dev/null | grep -qE '^php8\.3-fpm\.service[[:space:]]'; then
    return 1
  fi

  return 0
}

releasepanel_write_base_image_marker() {
  install -d -m 0755 /etc/releasepanel
  local ts php_v commit
  ts="$(date -u +'%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u 2>/dev/null || printf 'unknown')"
  php_v="$(php -r 'echo PHP_VERSION;' 2>/dev/null || php8.3 -r 'echo PHP_VERSION;' 2>/dev/null || echo 'unknown')"
  commit="$(_rp_apt_runner_git_short)"

  {
    printf '%s\n' "# releasepanel base image marker (hints only — verify binaries each run)"
    printf 'timestamp=%s\n' "${ts}"
    printf 'php_version=%s\n' "${php_v}"
    printf 'runner_commit=%s\n' "${commit}"
  } >/etc/releasepanel/base-image-ready
  chmod 0644 /etc/releasepanel/base-image-ready 2>/dev/null || true
}

ensure_apt_acquire_timeouts() {
  configure_apt_timeouts
}

force_fast_apt_mirrors() {
  apply_detected_mirror
}
