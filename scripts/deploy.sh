#!/usr/bin/env bash
# CodeBuild job: pull artifacts (ui-artifact.zip / api-artifact.zip / db-artifact.zip or releases/<role>-LATEST)
# from S3 onto each EC2 instance via SSM Run Command, install dependencies, and deploy.
# Needs env: ARTIFACT_BUCKET. Optional: ROLE (all|ui|api|db, default "all"), RELEASE (default "latest").
set -euo pipefail
source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

TARGET_ROLE="${ROLE:-all}"
RELEASE="${RELEASE:-latest}"
DB_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$DB_PASSWORD_PARAM" \
  --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "FdeTaskPass123456")
export ARTIFACT_BUCKET RELEASE DB_PASSWORD

instance_field() {  # role field(InstanceId|PrivateIpAddress|PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:App,Values=$APP_NAME" "Name=tag:Role,Values=$1" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$2" --output text
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

run_on() {  # role "ENV=val ENV2=val2"
  local role=$1 envs=$2 id v params cmd_id status
  local tar_url="" sum_url="" zip_url=""
  id=$(instance_field "$role" InstanceId)
  [ "$id" = "None" ] && { echo "No running '$role' instance. Run the provision step first."; exit 1; }
  v=$(resolve_version "$role")
  echo "== Deploying $role (version: $v) to instance $id =="

  # Resolve artifact in S3 and generate presigned URLs using CodeBuild's IAM permissions
  # (avoids 403 Forbidden if the EC2 instance profile lacks s3:GetObject on this bucket).
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
import json, os, sys
role, envs, v = sys.argv[1], sys.argv[2], sys.argv[3]
r = os.environ["AWS_REGION"]
tar_url = os.environ.get("TAR_URL", "")
sum_url = os.environ.get("SUM_URL", "")
zip_url = os.environ.get("ZIP_URL", "")
d = "/tmp/fde-release"

cmds = [
  "set -e",
  "export DEBIAN_FRONTEND=noninteractive",
  "export PATH=$PATH:/snap/bin:/usr/local/bin",
  "echo 'Waiting for cloud-init (first-boot user-data) to finish...'",
  "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null 2>&1 || true; fi",
  "while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done",
  "while snap changes 2>/dev/null | grep -q 'Doing'; do sleep 2; done",
  "dpkg -s unzip curl >/dev/null 2>&1 || (apt-get -o DPkg::Lock::Timeout=300 update -y && apt-get -o DPkg::Lock::Timeout=300 install -y unzip curl)",
  f"rm -rf {d} && mkdir -p {d}",
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
  f"env AWS_REGION={r} APP_VERSION={v} DB_PASSWORD_PARAM={os.environ['DB_PASSWORD_PARAM']} DB_PASSWORD={os.environ['DB_PASSWORD']} {envs} bash {d}/deploy/{role}.sh {d}",
]

print(json.dumps({"executionTimeout": ["1800"], "commands": cmds}))
PY
)
  cmd_id=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --comment "$APP_NAME $role $v" --parameters "$params" \
    --query Command.CommandId --output text)

  for i in $(seq 1 180); do
    status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
      --query Status --output text 2>/dev/null || echo Pending)
    case $status in Pending|InProgress|Delayed) sleep 10 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
  [ "$status" = "Success" ] || { echo "$role deploy FAILED ($status)"; exit 1; }
}

DB_IP=$(instance_field db PrivateIpAddress)
API_IP=$(instance_field api PrivateIpAddress)
UI_PUBLIC_IP=$(instance_field ui PublicIpAddress)

if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "db" ]; then
  run_on db ""
fi
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "api" ]; then
  run_on api "DB_HOST=$DB_IP"
fi
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "ui" ]; then
  run_on ui "API_HOST=$API_IP"
fi

if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "ui" ]; then
  echo "== Smoke test via http://$UI_PUBLIC_IP =="
  for i in $(seq 1 12); do
    if curl -fsS -o /dev/null "http://$UI_PUBLIC_IP/"; then
      echo "UI OK -> http://$UI_PUBLIC_IP/"
      if [ "$API_IP" != "None" ]; then
        curl -fsS "http://$UI_PUBLIC_IP/api/health" && echo && echo "API OK -> http://$UI_PUBLIC_IP/docs" || true
      fi
      exit 0
    fi
    sleep 5
  done
  echo "Smoke test failed"; exit 1
fi
