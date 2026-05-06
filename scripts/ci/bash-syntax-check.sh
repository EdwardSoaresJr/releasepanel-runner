#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash -n scripts/lib/apt-optimizations.sh
bash -n scripts/provision/laravel-byos.sh
bash -n scripts/install.sh
bash -n agent/install.sh
bash -n toolkit/scripts/install-agent-from-repo.sh
bash -n scripts/site/setup-laravel-site.sh
