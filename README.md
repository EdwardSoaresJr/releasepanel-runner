# Managed Deploy Agent

Public **on-server agent** for customer VPSes: a small **Node.js** process plus an embedded **shell toolkit** under `toolkit/`. It connects each server to **your** hosted control plane (private product) over HTTPS—**this repository is not your control plane** and does not install it.

## Install layout

| Path | Purpose |
|------|---------|
| Root (`server.js`, `package.json`, …) | Agent HTTP API (localhost) |
| **`toolkit/`** | Shared deploy scripts (nginx, SSL, site deploy, workers) synced from your private deploy repo |

Default clone directory: **`/opt/managed-deploy-agent`**. Override clone target with **`MANAGED_AGENT_INSTALL_DIR`** when piping `install-managed-vps.sh`.

**Fresh server:** the bootstrap expects a **new Ubuntu VPS** with **no** `nginx`, `apache2`, `caddy`, or `lighttpd` installed yet. If you must install on a box that already has a web stack, set **`MANAGED_AGENT_SKIP_FRESH_SERVER_CHECK=1`** (you are responsible for port/site conflicts).

The control plane calls the agent with header **`X-Managed-Agent-Key`** (legacy **`X-RELEASEPANEL-KEY`** is still accepted). Configure the shared secret as **`MANAGED_AGENT_RUNNER_KEY`** (or legacy **`RELEASEPANEL_RUNNER_KEY`**) in `.env`.

## Quick install (customer VPS)

From the control plane UI, copy the **bootstrap** command, or:

```bash
curl -fsSL https://raw.githubusercontent.com/EdwardSoaresJr/releasepanel-runner/main/scripts/install-managed-vps.sh | \
  MANAGED_AGENT_PANEL_URL='https://your-control-plane' \
  MANAGED_AGENT_SERVER_ID='server-id-from-panel' \
  MANAGED_AGENT_RUNNER_KEY='runner-key-from-panel' \
  bash -s
```

The GitHub repo is currently **`releasepanel-runner`**; install still uses **`/opt/managed-deploy-agent`** as the default install directory unless you set **`MANAGED_AGENT_INSTALL_DIR`**. After you rename the repo on GitHub, set **`MANAGED_AGENT_RUNNER_REPO_HTTPS`** (or we will update the default).

## Self-signed HTTPS control plane (staging)

For **`https://`** panel URLs that use a self-signed certificate:

1. During bootstrap: set **`MANAGED_AGENT_REGISTER_INSECURE_TLS=1`** on the install command (already skips TLS verify for `register-runner` and writes **`MANAGED_AGENT_PANEL_INSECURE_TLS=1`** into `.env` so **heartbeats** keep working).
2. Or add manually to `.env`: **`MANAGED_AGENT_PANEL_INSECURE_TLS=1`** (alias **`RELEASEPANEL_PANEL_INSECURE_TLS=1`**), then restart the agent.

Use real CA-backed TLS in production when possible.

## Maintainer sync

Canonical sources live in the **private** **releasepanel-deploy** monorepo. After changing toolkit shells, the Node agent, or **`install.sh` / `install-managed-vps.sh`** there, push the public bundle from that repo:

```bash
cd /path/to/releasepanel-deploy
./scripts/publish-releasepanel-runner.sh /path/to/releasepanel-runner
cd /path/to/releasepanel-runner
npm ci
git diff
git commit -am "Sync from releasepanel-deploy"   # or commit selectively
git push
```

`publish-releasepanel-runner.sh` calls `export-public-runner-toolkit.sh`, which omits control-plane-only scripts (bootstrap panel, self-update, etc.); those stay in the private repo only. Reconcile **`toolkit/bin/releasepanel`** in this tree if you hand-edit the agent CLI. See **`REPO_RECREATE.md`** for a clean GitHub history / rename checklist.

## Repo recreation

To drop old history or the previous GitHub name, follow **`REPO_RECREATE.md`**, then set **`RELEASEPANEL_RUNNER_BOOTSTRAP_INSTALL_URL`** on the control plane if the raw install URL changes.

## License

MIT
