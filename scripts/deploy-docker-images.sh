#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

RELEASE="${RELEASE:-latest}"
[[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid release version: $RELEASE" >&2
  exit 1
}
if [ "$RELEASE" = "latest" ]; then
  RELEASE="$(aws s3 cp "s3://${ARTIFACT_BUCKET}/releases/docker-LATEST" - \
    --region "$AWS_REGION" | tr -d '[:space:]')"
fi
[ -n "$RELEASE" ] || { echo "Could not resolve Docker release" >&2; exit 1; }

INSTANCE_ID="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:App,Values=$APP_NAME" Name=tag:Role,Values=container \
    Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
[ "$INSTANCE_ID" != "None" ] || {
  echo "No running container instance found; provisioning failed or has not run" >&2
  exit 1
}

echo "Deploying Docker release $RELEASE to $INSTANCE_ID"
PARAMS="$(python3 - "$ARTIFACT_BUCKET" "$AWS_REGION" "$RELEASE" \
  "$DOCKER_DB_PASSWORD_PARAM" "$DOCKER_DB_ROOT_PASSWORD_PARAM" <<'PY'
import base64
import json
import re
import sys

bucket, region, release, db_password_param, db_root_password_param = sys.argv[1:]
if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
    raise SystemExit("Invalid S3 bucket name")
if not re.fullmatch(r"[a-z0-9-]+", region):
    raise SystemExit("Invalid AWS region")
if not re.fullmatch(r"[A-Za-z0-9._-]+", release):
    raise SystemExit("Invalid release version")
for name in (db_password_param, db_root_password_param):
    if not re.fullmatch(r"/?[A-Za-z0-9_.\-/]+", name):
        raise SystemExit("Invalid SSM parameter name")

prefix = f"s3://{bucket}/releases/docker/{release}"
commands = [
    "set -eu",
    "STEP=initialization",
    "trap 'rc=$?; if [ \"$rc\" -ne 0 ]; then echo \"Deployment failed during: ${STEP:-unknown} (exit $rc)\" >&2; if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f /opt/fde-task-app/compose.yaml ]; then docker compose --project-name fde-task-app --file /opt/fde-task-app/compose.yaml --env-file /opt/fde-task-app/.env ps -a >&2 || true; docker compose --project-name fde-task-app --file /opt/fde-task-app/compose.yaml --env-file /opt/fde-task-app/.env logs --tail=80 db api ui >&2 || true; fi; fi' EXIT",
    "export DEBIAN_FRONTEND=noninteractive",
    "STEP='waiting for cloud-init'",
    "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null; fi",
    "STEP='installing Docker prerequisites'",
    "if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then apt-get update -y && apt-get install -y docker.io docker-compose-v2 curl unzip ca-certificates; fi",
    "STEP='installing AWS CLI v2'",
    "if ! command -v aws >/dev/null 2>&1; then arch=\"$(uname -m)\"; case \"$arch\" in x86_64|aarch64) ;; *) echo \"Unsupported EC2 architecture: $arch\" >&2; exit 1 ;; esac; workdir=\"$(mktemp -d)\"; if ! curl --fail --silent --show-error --location \"https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip\" --output \"$workdir/awscliv2.zip\" || ! unzip -q \"$workdir/awscliv2.zip\" -d \"$workdir\" || ! \"$workdir/aws/install\" --update; then rm -rf \"$workdir\"; exit 1; fi; rm -rf \"$workdir\"; fi",
    "STEP='starting Docker'",
    "systemctl enable --now docker",
    "STEP='preparing release directory'",
    "install -d -m 0755 /opt/fde-task-app/db /opt/fde-task-app/releases",
    f"install -d -m 0755 /opt/fde-task-app/releases/{release}",
    "STEP='downloading image archive from S3'",
    f"aws s3 cp '{prefix}/images.tar.gz' '/opt/fde-task-app/releases/{release}/images.tar.gz' --region '{region}'",
    "STEP='downloading archive checksum'",
    f"aws s3 cp '{prefix}/SHA256SUMS' '/opt/fde-task-app/releases/{release}/SHA256SUMS' --region '{region}'",
    "STEP='verifying image archive'",
    f"cd '/opt/fde-task-app/releases/{release}' && sha256sum -c SHA256SUMS",
    "STEP='downloading Compose and database schema'",
    f"aws s3 cp '{prefix}/compose.yaml' '/opt/fde-task-app/releases/{release}/compose.yaml' --region '{region}'",
    f"aws s3 cp '{prefix}/db/init.sql' '/opt/fde-task-app/releases/{release}/init.sql' --region '{region}'",
    "STEP='loading Docker images'",
    f"docker load --input '/opt/fde-task-app/releases/{release}/images.tar.gz'",
    "STEP='installing Compose and database schema'",
    f"install -m 0644 '/opt/fde-task-app/releases/{release}/compose.yaml' /opt/fde-task-app/compose.yaml",
    f"install -m 0644 '/opt/fde-task-app/releases/{release}/init.sql' /opt/fde-task-app/db/init.sql",
    "STEP='reading database credentials from SSM'",
    f"DB_PASSWORD=\"$(aws ssm get-parameter --name '{db_password_param}' --with-decryption --region '{region}' --query Parameter.Value --output text)\"",
    f"DB_ROOT_PASSWORD=\"$(aws ssm get-parameter --name '{db_root_password_param}' --with-decryption --region '{region}' --query Parameter.Value --output text)\"",
    "STEP='validating database credentials'",
    "for secret in \"$DB_PASSWORD\" \"$DB_ROOT_PASSWORD\"; do case \"$secret\" in ''|*[!A-Za-z0-9._~-]*) echo 'Database credentials must use only letters, digits, dot, underscore, tilde, or hyphen' >&2; exit 1 ;; esac; if [ \"${#secret}\" -lt 16 ] || [ \"${#secret}\" -gt 128 ]; then echo 'Database credentials must be between 16 and 128 characters' >&2; exit 1; fi; done",
    "STEP='writing Compose environment'",
    "umask 077",
    f"printf 'IMAGE_TAG=%s\\nHTTP_PORT=80\\nDB_PASSWORD=%s\\nDB_ROOT_PASSWORD=%s\\n' '{release}' \"$DB_PASSWORD\" \"$DB_ROOT_PASSWORD\" > /opt/fde-task-app/.env",
    "unset DB_PASSWORD DB_ROOT_PASSWORD",
    "STEP='starting Docker Compose services'",
    "docker compose --project-name fde-task-app --file /opt/fde-task-app/compose.yaml --env-file /opt/fde-task-app/.env up --detach --remove-orphans",
    "STEP='waiting for API health check'",
    "for attempt in $(seq 1 60); do if curl --fail --silent http://127.0.0.1/api/health >/dev/null; then break; fi; if [ \"$attempt\" -eq 60 ]; then docker compose --project-name fde-task-app --file /opt/fde-task-app/compose.yaml --env-file /opt/fde-task-app/.env ps; exit 1; fi; sleep 2; done",
    "STEP='checking UI and API endpoints'",
    "curl --fail --silent http://127.0.0.1/ >/dev/null",
    "curl --fail --silent http://127.0.0.1/api/health",
    "STEP=complete",
]
script = "\n".join(commands)
encoded_script = base64.b64encode(script.encode()).decode()
ssm_command = f"printf '%s' '{encoded_script}' | base64 --decode | bash"
print(json.dumps({"executionTimeout": ["3600"], "commands": [ssm_command]}))
PY
)"

COMMAND_ID="$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --comment "$APP_NAME Docker release $RELEASE" \
  --parameters "$PARAMS" --query Command.CommandId --output text)"

for attempt in $(seq 1 180); do
  STATUS="$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Pending|InProgress|Delayed) sleep 10 ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text
aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query StandardErrorContent --output text >&2
aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,StatusDetails:StatusDetails,ResponseCode:ResponseCode,ExecutionElapsedTime:ExecutionElapsedTime}' \
  --output table
[ "$STATUS" = "Success" ] || {
  echo "Docker deployment failed with SSM status $STATUS" >&2
  exit 1
}

PUBLIC_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "Docker release $RELEASE is live at http://$PUBLIC_IP/"
