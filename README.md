# FDE Task Tracker — Single Instance Deployment (`singleInstance` branch)

All three tiers (**Nginx UI**, **FastAPI API**, and **MySQL DB**) deployed step-by-step onto a **single Ubuntu 24.04 EC2 instance** (`fde-task-app-single`, `t3.medium`) in **Asia Pacific (Hyderabad) `ap-south-2`** using AWS CodeBuild, S3, and AWS Systems Manager (SSM).

```text
 CodeCommit / Git (singleInstance branch)
      │
      ├─► CodeBuild Source/Build Jobs:
      │     • buildspec-db-src.yml   ──► s3://fde-artifacts/db-artifact.zip  (& releases/<ver>/db.tar.gz)
      │     • buildspec-api-src.yml  ──► s3://fde-artifacts/api-artifact.zip (& releases/<ver>/api.tar.gz)
      │     • buildspec-ui-src.yml   ──► s3://fde-artifacts/ui-artifact.zip  (& releases/<ver>/ui.tar.gz)
      │
      └─► CodeBuild Deploy Jobs (Step-by-Step onto 1 Single EC2 Instance via SSM):
            • Step 1: Provision Single EC2 Instance (fde-task-app-single, SG port 80)
            • Step 2: Deploy DB  (MySQL 8.0 on 127.0.0.1:3306, schema init.sql)
            • Step 3: Deploy API (FastAPI + Uvicorn systemd on 127.0.0.1:8000 -> DB 127.0.0.1:3306)
            • Step 4: Deploy UI  (Nginx on :80 serving /var/www/fde-task-app -> API 127.0.0.1:8000)
```

Traffic on the single instance:
`Internet :80 → Nginx (/var/www/fde-task-app) → FastAPI 127.0.0.1:8000 → MySQL 127.0.0.1:3306`.
Only HTTP port `80` is exposed in the Security Group (`fde-task-app-sg`); API and MySQL stay bound to `127.0.0.1`.

---

## Step-by-Step Deployment via CodeBuild

### Phase 1: Build & Push Artifacts to S3 (`s3://fde-artifacts`)
Run the three artifact build jobs in CodeBuild:
1. **DB Artifact Build**: `buildspecs/buildspec-db-src.yml`
2. **API Artifact Build**: `buildspecs/buildspec-api-src.yml`
3. **UI Artifact Build**: `buildspecs/buildspec-ui-src.yml`

---

### Phase 2: Provision & Deploy onto the Single EC2 Instance
You can deploy onto the single EC2 instance (`fde-task-app-single`) either **in one unified step-by-step job** or **using the 3 individual deploy jobs**:

#### Option A: Single Unified Job (All 4 Steps in One Build)
Use **`buildspecs/buildspec-single-deploy.yml`**:
- **Step 1 (`pre_build`)**: Runs `bash scripts/provision.sh` to create/reuse the `fde-task-app-sg` security group (port `80`) and launch/reuse the single Ubuntu 24.04 EC2 instance (`fde-task-app-single`).
- **Step 2 (`build`)**: Runs `ROLE=db bash scripts/deploy.sh` to pull `db` artifact from S3 and configure MySQL on `127.0.0.1:3306`.
- **Step 3 (`build`)**: Runs `ROLE=api bash scripts/deploy.sh` to pull `api` artifact from S3 and start `fde-task-app.service` on `127.0.0.1:8000`.
- **Step 4 (`build`)**: Runs `ROLE=ui bash scripts/deploy.sh` to pull `ui` artifact from S3, publish static files to `/var/www/fde-task-app`, configure Nginx reverse proxy to `127.0.0.1:8000`, and run the smoke test.

#### Option B: Separate Deploy Jobs (One Tier at a Time onto the Same Instance)
All three deploy buildspecs automatically reuse the **same** `fde-task-app-single` EC2 instance:
1. **DB Deploy**: `buildspecs/buildspec-db-deploy.yml` (provisions `fde-task-app-single` if not running + deploys MySQL)
2. **API Deploy**: `buildspecs/buildspec-api-deploy.yml` (reuses `fde-task-app-single` + deploys FastAPI)
3. **UI Deploy**: `buildspecs/buildspec-ui-deploy.yml` (reuses `fde-task-app-single` + deploys Nginx UI & smoke tests `http://<PUBLIC_IP>/`)

---

## Tear Down
```bash
bash scripts/destroy.sh
```
Terminates the `fde-task-app-single` EC2 instance and deletes the security group.
