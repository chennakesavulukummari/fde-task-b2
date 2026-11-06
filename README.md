# FDE Task Tracker — Single Instance Deployment

All three tiers (**Nginx UI**, **FastAPI API**, and **MySQL DB**) deployed step-by-step onto a **single Ubuntu 24.04 EC2 instance** (`fde-task-app-single`, `t3.medium`) in **Asia Pacific (Hyderabad) `ap-south-2`** using AWS CodeBuild, S3, and AWS Systems Manager (SSM).

## Docker images via S3 and deployment to a new EC2 instance

The container flow is separate from the existing native deployment above. It leaves the existing EC2 instance and its MySQL data untouched, and provisions a separate container host.

### Build job

Create a CodeBuild project using `buildspecs/buildspec-docker-images.yml`. Enable **Privileged** mode so Docker can build images. Set the project’s source to this repository/branch and grant its service role permission to upload objects to `s3://fde-artifacts` (or set `ARTIFACT_BUCKET` to your bucket).

Run the job to build the UI and API images, include the pinned MySQL image, and upload a versioned `images.tar.gz` plus the Compose file and schema to `s3://<bucket>/releases/docker/<version>/`. The job also updates `releases/docker-LATEST`.

### Deploy job

Create a second CodeBuild project using `buildspecs/buildspec-docker-deploy.yml`. Its service role needs the EC2, IAM (including `iam:PassRole`), SSM Parameter Store, SSM Run Command, and S3 permissions used by the provisioning/deployment scripts. Set `ARTIFACT_BUCKET` and `AWS_REGION` as project environment variables; defaults are `fde-artifacts` and `ap-south-2`.

The job provisions (or reuses) an EC2 instance tagged with role `container`, sets up a separate HTTP security group and a dedicated EC2 instance role, and deploys through SSM. The instance role can read only this app's Docker release objects and the two database SecureString parameters; it does not modify the existing deployment's instance profile. The instance downloads the image archive from S3, loads it into Docker, writes runtime database credentials from SSM Parameter Store, and starts Compose. If the two Docker-specific SecureString parameters do not exist, provisioning creates random credentials at `/${APP_NAME}/docker/db-password` and `/${APP_NAME}/docker/db-root-password`. Only port 80 is exposed by default; API and MySQL ports are not published.

The Compose stack publishes the UI on host port 80 and persists MySQL data in a Docker volume on the instance. The initialization script runs only when that volume is first created. Back up the volume before terminating or replacing the container instance.

Set `RELEASE` on the deploy CodeBuild run to deploy a specific version; otherwise it deploys `latest`. Re-running the build job creates a new version and advances the `latest` pointer.

### Run the Compose stack locally

1. Copy `.env.example` to `.env`, set unique, strong `DB_PASSWORD` and `DB_ROOT_PASSWORD` values, and restrict access to the file. Do not commit `.env`.

   ```bash
   cp .env.example .env
   chmod 600 .env
   ```
2. Build images and start the stack:

   ```bash
   docker build -t fde-task-api:latest ./api
   docker build -t fde-task-ui:latest ./ui
   docker compose up -d
   ```

3. Open `http://localhost/`. The UI proxies `/api/` requests to the API; only the UI is published on the host. MySQL data is kept in the `mysql_data` named volume.

Useful commands:

```bash
docker compose ps
docker compose logs -f
docker compose down
```

`docker compose down` preserves the database volume. To permanently discard the database, use `docker compose down --volumes`; this deletes all persisted task data. The MySQL initialization script runs only when the data volume is first created.

For EC2, allow inbound HTTP on port 80 and keep the API and database ports closed to the public internet. `docker compose down` preserves the database volume; `docker compose down --volumes` deletes it.

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
