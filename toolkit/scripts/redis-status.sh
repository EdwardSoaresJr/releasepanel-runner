#!/usr/bin/env bash
#
# ReleasePanel Redis health (control plane).
set -Eeuo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PATH="/var/www/sites/releasepanel-app/production"

echo "=== redis-cli ping ==="
if command -v redis-cli >/dev/null 2>&1; then
    redis-cli ping || echo "[warn] Redis not responding"
else
    echo "[warn] redis-cli not installed"
fi

echo ""
echo "=== Redis service ==="
if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active redis-server 2>/dev/null && echo "redis-server: active" || echo "redis-server: inactive"
fi

if [ ! -f "${BASE_PATH}/current/artisan" ]; then
    echo "[warn] Panel not found at ${BASE_PATH}/current"
    exit 0
fi

echo ""
echo "=== Queue lengths (redis-cli; prefix-agnostic) ==="
if command -v redis-cli >/dev/null 2>&1 && [ "$(redis-cli ping 2>/dev/null || true)" = "PONG" ]; then
    for q in default deployments runners maintenance; do
        key="$(redis-cli --scan --pattern "*queues:${q}" 2>/dev/null | head -n 1)"
        if [ -n "${key}" ]; then
            len="$(redis-cli llen "${key}" 2>/dev/null || echo "?")"
            echo "${q} -> ${len} (${key})"
        else
            echo "${q} -> 0 (no matching key)"
        fi
    done
else
    echo "[warn] redis not reachable; skipped"
fi

echo ""
echo "=== Laravel cache store probe ==="
sudo -u releasepanel bash -lc "cd $(printf '%q' "${BASE_PATH}/current") && php artisan tinker --execute=\"
    try {
        Cache::store(config('cache.default'))->put('_rp_health', '1', 5);
        echo config('cache.default').': ok'.PHP_EOL;
    } catch (Throwable \\\$e) {
        echo 'cache probe failed: '.\\\$e->getMessage().PHP_EOL;
    }
\"" 2>/dev/null || echo "[warn] cache probe failed"
