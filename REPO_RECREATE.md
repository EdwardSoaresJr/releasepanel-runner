# Recreating the public agent repository

Use this when replacing **`releasepanel-runner`** (or any prior name) with **`managed-deploy-agent`** and a **fresh Git history**.

## 1. Create the new GitHub repository

- Create **`managed-deploy-agent`** (or your final name) as an empty public repo.
- Do **not** add a README or license on GitHub if you want a single initial commit from your machine.

## 2. Point the control plane at the new bootstrap URL

Set on the **ReleasePanel** app host (or `.env` / secrets):

- `RELEASEPANEL_RUNNER_BOOTSTRAP_INSTALL_URL`  
  Example:  
  `https://raw.githubusercontent.com/EdwardSoaresJr/managed-deploy-agent/main/scripts/install-managed-vps.sh`

The default in `config/releasepanel.php` already targets **`managed-deploy-agent`**; adjust org/repo if yours differs.

Clear config cache after changing env:

```bash
php artisan config:clear
```

## 3. Optional: archive the old repo

- GitHub: archive **`releasepanel-runner`** or rename it to **`releasepanel-runner-deprecated`**.
- Add a short README there pointing to **`managed-deploy-agent`**.

## 4. Push this tree as the new `main`

From your local checkout (this directory):

```bash
git remote remove origin 2>/dev/null || true
git remote add origin git@github.com:YOUR_ORG/managed-deploy-agent.git
git branch -M main
git push -u origin main
```

For a **single squashed** initial commit (destructive locally):

```bash
git checkout --orphan clean-main
git add -A
git commit -m "Initial public managed deploy agent"
git branch -D main
git branch -m main
git push -f -u origin main
```

## 5. Customer servers already on `/opt/releasepanel-runner`

Existing installs keep working until you migrate them:

- They still use legacy env keys and paths unless you re-run install or update `.env` and systemd.
- Migrate by installing the new unit **`managed-deploy-agent.service`**, updating paths to `/opt/managed-deploy-agent`, or re-running the bootstrap curl from the panel.

## 6. What still mentions `RELEASEPANEL_*` in this repo

The **vendored toolkit** (under `toolkit/`) stays compatible with the private deploy repo’s **site `.env` keys** (e.g. `RELEASEPANEL_BASE`, `RELEASEPANEL_REPO`). Those names are **deploy toolkit** semantics, not branding of the control plane. Renaming them would require a coordinated change in the private deploy repo and every site env file.

## 7. systemd migration on a live box

```bash
sudo systemctl disable --now releasepanel-runner 2>/dev/null || true
sudo rm -f /etc/systemd/system/releasepanel-runner.service
# Re-run scripts/install.sh from the new clone or use install-runner from toolkit
sudo systemctl daemon-reload
sudo systemctl enable --now managed-deploy-agent
```
