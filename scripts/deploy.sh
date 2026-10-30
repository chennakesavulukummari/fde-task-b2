#!/usr/bin/env bash
# CodeBuild job 3: pull a release from S3 onto each EC2 instance via SSM Run Command.
# Order: db -> api -> ui, then an end-to-end smoke test from CodeBuild.
# Needs env: ARTIFACT_BUCKET. Optional: RELEASE (default "latest").
set -euo pipefail
source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

RELEASE="${RELEASE:-latest}"
if [ "$RELEASE" = "latest" ]; then
  RELEASE=$(aws s3 cp "s3://$ARTIFACT_BUCKET/releases/LATEST" - | tr -d '[:space:]')
fi
aws s3 ls "s3://$ARTIFACT_BUCKET/releases/$RELEASE/manifest.json" >/dev/null \
  || { echo "Release $RELEASE not found in S3"; exit 1; }
echo "Deploying release: $RELEASE"

instance_field() {  # role field(InstanceId|PrivateIpAddress|PublicIpAddress)
  aws ec2 describe-instances \
    --filters "Name=tag:App,Values=$APP_NAME" "Name=tag:Role,Values=$1" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$2" --output text
}

run_on() {  # role "ENV=val ENV2=val2"
  local role=$1 envs=$2 id params cmd_id status
  id=$(instance_field "$role" InstanceId)
  [ "$id" = "None" ] && { echo "No running '$role' instance. Run the provision job first."; exit 1; }
  echo "== Deploying $role to $id =="

  params=$(python3 - "$role" "$envs" <<'PY'
import json, os, sys
role, envs = sys.argv[1], sys.argv[2]
b, v, r = os.environ["ARTIFACT_BUCKET"], os.environ["RELEASE"], os.environ["AWS_REGION"]
d = "/tmp/fde-release"
print(json.dumps({"executionTimeout": ["1800"], "commands": [
  "set -e",
  "export PATH=$PATH:/snap/bin",
  "command -v aws >/dev/null || snap install aws-cli --classic",
  f"rm -rf {d} && mkdir -p {d}",
  f"aws s3 cp s3://{b}/releases/{v}/{role}.tar.gz {d}/ --region {r}",
  f"aws s3 cp s3://{b}/releases/{v}/SHA256SUMS {d}/ --region {r}",
  f"cd {d} && grep ' {role}.tar.gz$' SHA256SUMS | sha256sum -c -",
  f"tar -xzf {d}/{role}.tar.gz -C {d}",
  f"env AWS_REGION={r} APP_VERSION={v} DB_PASSWORD_PARAM={os.environ['DB_PASSWORD_PARAM']} {envs} bash {d}/deploy/{role}.sh {d}",
]}))
PY
)
  export RELEASE
  cmd_id=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --comment "$APP_NAME $role $RELEASE" --parameters "$params" \
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

export RELEASE
DB_IP=$(instance_field db PrivateIpAddress)
API_IP=$(instance_field api PrivateIpAddress)
UI_PUBLIC_IP=$(instance_field ui PublicIpAddress)

run_on db  ""
run_on api "DB_HOST=$DB_IP"
run_on ui  "API_HOST=$API_IP"

echo "== Smoke test via http://$UI_PUBLIC_IP =="
for i in $(seq 1 12); do
  if curl -fsS "http://$UI_PUBLIC_IP/api/health"; then
    echo; curl -fsS -o /dev/null "http://$UI_PUBLIC_IP/" && echo "UI OK"
    echo "Deployed $RELEASE  ->  http://$UI_PUBLIC_IP/   (API docs: http://$UI_PUBLIC_IP/docs)"
    exit 0
  fi
  sleep 5
done
echo "Smoke test failed"; exit 1
