#!/usr/bin/env bash
# CodeBuild job (Single Instance branch): pull artifacts (db, api, ui) from S3 onto the
# SINGLE EC2 instance via SSM Run Command, install dependencies, and deploy step by step.
# Needs env: ARTIFACT_BUCKET. Optional: ROLE (all|db|api|ui, default "all"), RELEASE (default "latest").
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

TARGET_ROLE="${ROLE:-all}"
RELEASE="${RELEASE:-latest}"
DB_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$DB_PASSWORD_PARAM" \
  --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "FdeTaskPass123456")
export ARTIFACT_BUCKET RELEASE DB_PASSWORD REPO_ROOT

single_instance_field() {  # field(InstanceId|PrivateIpAddress|PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:App,Values=$APP_NAME" "Name=tag:Role,Values=single" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$1" --output text
}

resolve_version() {  # role -> release version string
  local role=$1 v=""
  if [ "$RELEASE" != "latest" ]; then
    echo "$RELEASE"
    return
  fi
  v=$(aws s3 cp "s3://$ARTIFACT_BUCKET/releases/${role}-LATEST" - 2>/dev/null | tr -d '[:space:]' || true)
  if [ -z "$v" ]; then
    v=$(aws s3 cp "s3://$ARTIFACT_BUCKET/releases/LATEST" - 2>/dev/null | tr -d '[:space:]' || echo "latest")
  fi
  echo "$v"
}

SINGLE_ID=$(single_instance_field InstanceId)
[ "$SINGLE_ID" = "None" ] && { echo "No running single instance found. Run scripts/provision.sh first."; exit 1; }
PUBLIC_IP=$(single_instance_field PublicIpAddress)

run_on_single() {  # role "ENV=val ENV2=val2"
  local role=$1 envs=$2 id="$SINGLE_ID" v params cmd_id status
  local tar_url="" sum_url="" zip_url=""
  v=$(resolve_version "$role")
  echo "== Deploying $role (version: $v) to single instance $id ($PUBLIC_IP) =="

  # Resolve artifact in S3 and generate presigned URLs using CodeBuild's IAM permissions
  if [ "$v" != "latest" ] && aws s3 ls "s3://$ARTIFACT_BUCKET/releases/$v/${role}.tar.gz" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Resolved S3 artifact: s3://$ARTIFACT_BUCKET/releases/$v/${role}.tar.gz"
    tar_url=$(aws s3 presign "s3://$ARTIFACT_BUCKET/releases/$v/${role}.tar.gz" --region "$AWS_REGION" --expires-in 3600)
    if aws s3 ls "s3://$ARTIFACT_BUCKET/releases/$v/SHA256SUMS" --region "$AWS_REGION" >/dev/null 2>&1; then
      sum_url=$(aws s3 presign "s3://$ARTIFACT_BUCKET/releases/$v/SHA256SUMS" --region "$AWS_REGION" --expires-in 3600)
    fi
  elif aws s3 ls "s3://$ARTIFACT_BUCKET/${role}-artifact.zip" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Resolved S3 artifact: s3://$ARTIFACT_BUCKET/${role}-artifact.zip"
    zip_url=$(aws s3 presign "s3://$ARTIFACT_BUCKET/${role}-artifact.zip" --region "$AWS_REGION" --expires-in 3600)
  elif aws s3 ls "s3://$ARTIFACT_BUCKET/${role}-artifact/${role}.tar.gz" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Resolved S3 artifact: s3://$ARTIFACT_BUCKET/${role}-artifact/${role}.tar.gz"
    tar_url=$(aws s3 presign "s3://$ARTIFACT_BUCKET/${role}-artifact/${role}.tar.gz" --region "$AWS_REGION" --expires-in 3600)
  else
    echo "ERROR: Could not find ${role} artifact in s3://$ARTIFACT_BUCKET (checked releases/$v/${role}.tar.gz and ${role}-artifact.zip)"
    exit 1
  fi

  params=$(TAR_URL="$tar_url" SUM_URL="$sum_url" ZIP_URL="$zip_url" python3 - "$role" "$envs" "$v" <<'PY'
import base64, json, os, pathlib, sys
role, envs, v = sys.argv[1], sys.argv[2], sys.argv[3]
r = os.environ["AWS_REGION"]
repo_root = pathlib.Path(os.environ["REPO_ROOT"])
tar_url = os.environ.get("TAR_URL", "")
sum_url = os.environ.get("SUM_URL", "")
zip_url = os.environ.get("ZIP_URL", "")
d = f"/tmp/fde-release-{role}"

common_b64 = base64.b64encode((repo_root / "deploy" / "common.sh").read_bytes()).decode()
role_b64 = base64.b64encode((repo_root / "deploy" / f"{role}.sh").read_bytes()).decode()

cmds = [
  "set -e",
  "export DEBIAN_FRONTEND=noninteractive",
  "export PATH=$PATH:/snap/bin:/usr/local/bin",
  "echo 'Waiting for cloud-init (first-boot user-data) to finish...'",
  "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null 2>&1 || true; fi",
  "while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done",
  "while snap changes 2>/dev/null | grep -q 'Doing'; do sleep 2; done",
  "dpkg -s unzip curl >/dev/null 2>&1 || (apt-get -o DPkg::Lock::Timeout=300 update -y && apt-get -o DPkg::Lock::Timeout=300 install -y unzip curl)",
  f"rm -rf {d} && mkdir -p {d}/deploy",
]

if zip_url:
  cmds.append(f"echo 'Downloading {role}-artifact.zip from S3...'")
  cmds.append(f"curl -fsSL '{zip_url}' -o {d}/{role}-artifact.zip")
  cmds.append(f"unzip -o {d}/{role}-artifact.zip -d {d}")
elif tar_url:
  cmds.append(f"echo 'Downloading {role}.tar.gz from S3...'")
  cmds.append(f"curl -fsSL '{tar_url}' -o {d}/{role}.tar.gz")
  if sum_url:
    cmds.append(f"curl -fsSL '{sum_url}' -o {d}/SHA256SUMS")

cmds += [
  f"if [ -f {d}/SHA256SUMS ] && [ -f {d}/{role}.tar.gz ]; then cd {d} && grep ' {role}.tar.gz$' SHA256SUMS | sha256sum -c -; fi",
  f"if [ -f {d}/{role}.tar.gz ]; then tar -xzf {d}/{role}.tar.gz -C {d}; fi",
  f"echo '{common_b64}' | base64 -d > {d}/deploy/common.sh",
  f"echo '{role_b64}' | base64 -d > {d}/deploy/{role}.sh",
  f"chmod +x {d}/deploy/common.sh {d}/deploy/{role}.sh",
  f"env AWS_REGION={r} APP_VERSION={v} DB_PASSWORD_PARAM={os.environ['DB_PASSWORD_PARAM']} DB_PASSWORD={os.environ['DB_PASSWORD']} {envs} bash {d}/deploy/{role}.sh {d}",
]

print(json.dumps({"executionTimeout": ["1800"], "commands": cmds}))
PY
)
  cmd_id=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --comment "$APP_NAME single:$role $v" --parameters "$params" \
    --query Command.CommandId --output text)

  for i in $(seq 1 180); do
    status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
      --query Status --output text 2>/dev/null || echo Pending)
    case $status in Pending|InProgress|Delayed) sleep 10 ;; *) break ;; esac
  done
  echo "--- SSM StandardOutput ($role) ---"
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query 'StandardOutputContent' --output text
  echo "--- SSM StandardError ($role) ---"
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query 'StandardErrorContent' --output text
  [ "$status" = "Success" ] || { echo "$role deploy FAILED ($status)"; exit 1; }
}

# On a single instance, DB and API both run on 127.0.0.1
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "db" ]; then
  run_on_single db ""
fi
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "api" ]; then
  if [ "$TARGET_ROLE" = "api" ]; then
    echo "== Ensuring local MySQL DB (127.0.0.1:3306) is configured before starting API =="
    run_on_single db ""
  fi
  run_on_single api "DB_HOST=127.0.0.1"
fi
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "ui" ]; then
  run_on_single ui "API_HOST=127.0.0.1"
fi

if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "ui" ]; then
  echo "== Smoke test via http://$PUBLIC_IP =="
  for i in $(seq 1 12); do
    if curl -fsS -o /dev/null "http://$PUBLIC_IP/"; then
      echo "UI OK -> http://$PUBLIC_IP/"
      curl -fsS "http://$PUBLIC_IP/api/health" && echo && echo "API OK -> http://$PUBLIC_IP/docs" || true
      exit 0
    fi
    sleep 5
  done
  echo "Smoke test failed"; exit 1
fi
