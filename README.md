# FDE Task Tracker — CodeCommit → CodeBuild → S3 → EC2 (Ubuntu, ap-south-2)

Three-tier app (Nginx UI, FastAPI API, MySQL DB), each on its own Ubuntu 24.04 EC2
instance in **Asia Pacific (Hyderabad) `ap-south-2`**, delivered by three CodeBuild jobs.

```
 CodeCommit (fde-task-app, main)
      │
      ├─► CodeBuild: fde-task-app-provision ── AWS CLI ──► EC2: ui · api · db  (+ SGs)
      │
      ├─► CodeBuild: fde-task-app-build ── validate + package ──► S3 releases/<version>/
      │                                                           ui.tar.gz api.tar.gz db.tar.gz
      │
      └─► CodeBuild: fde-task-app-deploy ── SSM Run Command ──► each EC2 pulls its tarball
                                                                from S3 and runs deploy/<role>.sh
```

Traffic: `Internet :80 → UI (Nginx) → API :8000 (private IP) → DB :3306 (private IP)`.
Security groups allow only that chain. No SSH keys or port 22 — use SSM Session Manager.

## Repo layout

| Path | What it is |
|---|---|
| `ui/` | `index.html`, `styles.css`, `app.js`, `nginx.conf.tpl` (API IP injected at deploy) |
| `api/` | `app.py`, `requirements.txt`, `fde-task-app.service` (systemd) |
| `db/` | `init.sql` (database + `tasks` table, idempotent) |
| `deploy/` | Scripts that run **on the EC2 instances**: `db.sh`, `api.sh`, `ui.sh`, `common.sh` |
| `scripts/` | Scripts that run **in CodeBuild**: `build.sh`, `provision.sh`, `deploy.sh`, plus `destroy.sh` |
| `buildspecs/` | `build.yml`, `provision.yml`, `deploy.yml` — one per CodeBuild project |
| `bootstrap/setup.sh` | One-time: repo, bucket, IAM roles, DB password, 3 CodeBuild projects |
| `config.env` | Region, instance types, names — edit here |

## 1. One-time setup (CloudShell in ap-south-2 is easiest)

```bash
bash bootstrap/setup.sh
```

Creates the CodeCommit repo, a private versioned S3 bucket
(`fde-task-app-artifacts-<account>-ap-south-2`), a random DB password in SSM Parameter
Store (`/fde-task-app/db-password`, SecureString), the EC2 instance profile, the CodeBuild
role and the three CodeBuild projects. Re-running is safe.

## 2. Push the code to CodeCommit

```bash
pip install git-remote-codecommit        # uses your AWS credentials, no Git passwords
git init -b main && git add . && git commit -m "FDE task app: ui, api, db, pipeline"
git remote add origin codecommit::ap-south-2://fde-task-app
git push -u origin main
```

## 3. Run the jobs (in this order the first time)

```bash
aws codebuild start-build --project-name fde-task-app-provision --region ap-south-2
aws codebuild start-build --project-name fde-task-app-build     --region ap-south-2
aws codebuild start-build --project-name fde-task-app-deploy    --region ap-south-2
```

The deploy job's log ends with `Deployed <version> -> http://<UI_PUBLIC_IP>/`.
Swagger UI is at `http://<UI_PUBLIC_IP>/docs`.

After that, the normal loop is: **push → build → deploy**. Provision only needs to re-run
if instances are deleted (it reuses anything already there).

### Roll back / deploy a specific version

```bash
aws s3 ls s3://<bucket>/releases/
aws codebuild start-build --project-name fde-task-app-deploy --region ap-south-2 \
  --environment-variables-override name=RELEASE,value=20261030-150000-abc1234,type=PLAINTEXT
```

## What each job does

**build** — installs API deps and import-checks `app.py`, runs `node --check` on `app.js`,
checks the SQL and Nginx template, `bash -n` on every script, then packages
`ui/api/db.tar.gz` (each with its deploy script), writes `SHA256SUMS` and `manifest.json`,
uploads to `s3://<bucket>/releases/<UTC-timestamp>-<commit>/` and updates `releases/LATEST`.

**provision** — looks up the latest Canonical Ubuntu 24.04 AMI from the public SSM
parameter, uses the default VPC, creates three security groups, and launches
`fde-task-app-db` (t3.small), `-api` (t3.small) and `-ui` (t3.micro) with IMDSv2, an
encrypted 20 GB gp3 root volume, and user-data that preinstalls MySQL / Python / Nginx.
Waits until every instance is Online in SSM.

**deploy** — resolves the release, then for `db → api → ui` sends an SSM command that
downloads that role's tarball from S3, verifies its checksum and runs `deploy/<role>.sh`:
- `db.sh`: binds MySQL to the private network, applies `init.sql`, creates/rotates
  `fde_app@'%'` with the password from Parameter Store.
- `api.sh`: copies code to `/opt/fde-task-app`, writes `.env` (DB host = DB private IP),
  builds the venv, restarts the systemd service, waits for `/api/health`.
- `ui.sh`: copies static files to `/var/www/fde-task-app`, renders the Nginx config with the
  API private IP, reloads Nginx.
Finally CodeBuild curls the UI's public IP for an end-to-end check.

## Troubleshooting

```bash
# Shell on any instance without SSH
aws ssm start-session --target <instance-id> --region ap-south-2
sudo journalctl -u fde-task-app -n 80 --no-pager      # API
sudo systemctl status mysql nginx --no-pager
```

- **Instance never Online in SSM** → instance profile missing, or the subnet has no route to
  the internet (default VPC subnets do).
- **API health 503** → DB unreachable: check the DB SG allows 3306 from the API SG and that
  the `db` step of the deploy job succeeded.

## Tear down

```bash
bash scripts/destroy.sh     # terminates the 3 instances and deletes the SGs
```
The repo, bucket, IAM roles and CodeBuild projects stay; delete them from the console when done.

## Optional: automate the chain
Add an EventBridge rule on CodeCommit `referenceUpdated` (branch `main`) → start
`fde-task-app-build`, and a rule on CodeBuild `Build State Change = SUCCEEDED` for that project
→ start `fde-task-app-deploy`. Or wrap build + deploy in CodePipeline, which is also
available in ap-south-2.
