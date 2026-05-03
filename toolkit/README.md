# Embedded toolkit (app server + agent)

This tree is a **subset** of the shell toolkit from your **private deploy** repository. **Customer VPSes** clone the **public agent repo** only.

## Included

- `lib/`, `scripts/`, `systemd/` needed to prepare a generic app server (PHP, nginx, redis, supervisor), register with your control plane, run the **Node agent**, and drive **`releasepanel site …`** deploy/repair/nginx/ssl/workers for **customer apps**.

## Excluded from sync

Control-plane-only scripts (full panel bootstrap, self-update, panel-only workers, etc.) are **not** copied here via `export-public-runner-toolkit.sh`.

## `bin/releasepanel`

Maintained **in the public agent repo** (trimmed CLI). Export does **not** overwrite it.

## Maintainer sync

```bash
/path/to/deploy/scripts/export-public-runner-toolkit.sh /path/to/managed-deploy-agent
```

Then commit the updated `toolkit/` (except `bin/releasepanel` unless you intend to change it).

## Site env files

Per-app definitions live under `sites/{site}/{env}.env`. Keys such as `RELEASEPANEL_BASE`, `RELEASEPANEL_REPO`, … are **deploy-toolkit field names** shared with the private repo—not the product name of your control plane.
