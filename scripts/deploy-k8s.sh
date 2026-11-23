#!/usr/bin/env bash
# Pull container images from S3 onto the 3 Kubernetes nodes (containerd k8s.io namespace),
# create the 3 namespaces (db, api, ui), and deploy the 3 containers (db, api, ui) via kubectl.
set -euo pipefail

source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

RELEASE="${RELEASE:-latest}"
[[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid release version: $RELEASE" >&2
  exit 1
}
if [ "$RELEASE" = "latest" ]; then
  RELEASE="$(aws s3 cp "s3://${ARTIFACT_BUCKET}/releases/k8s-LATEST" - \
    --region "$AWS_REGION" | tr -d '[:space:]')"
fi
[ -n "$RELEASE" ] || { echo "Could not resolve Kubernetes release from S3" >&2; exit 1; }

CP_ID="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:App,Values=$APP_NAME" Name=tag:Role,Values=k8s-control-plane \
    Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
[ "$CP_ID" != "None" ] || { echo "No running k8s-control-plane instance found; run provision-k8s.sh first" >&2; exit 1; }

read -r -a WORKER_IDS <<< "$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:App,Values=$APP_NAME" Name=tag:Role,Values=k8s-worker \
    Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')"

if [ "${#WORKER_IDS[@]}" -lt 2 ]; then
  echo "Expected at least 2 running k8s-worker instances, found ${#WORKER_IDS[@]}" >&2
  exit 1
fi

ALL_IDS=("$CP_ID" "${WORKER_IDS[@]}")
echo "Deploying Kubernetes release $RELEASE across Control Plane ($CP_ID) and Workers (${WORKER_IDS[*]})"

run_ssm_script() {  # description script_body instance_id [instance_id...]
  local desc=$1 script=$2
  shift 2
  local ids=("$@") encoded params cmd_id status id
  encoded="$(printf '%s' "$script" | base64 | tr -d '\n')"
  params="$(python3 -c 'import json,sys; print(json.dumps({"executionTimeout":["3600"],"commands":[f"printf '\''%s'\'' '\''{sys.argv[1]}'\'' | base64 --decode | bash"]}))' "$encoded")"
  cmd_id="$(aws ssm send-command --region "$AWS_REGION" \
    --instance-ids "${ids[@]}" --document-name AWS-RunShellScript \
    --comment "$desc" --parameters "$params" --query Command.CommandId --output text)"
  for id in "${ids[@]}"; do
    for attempt in $(seq 1 180); do
      status="$(aws ssm get-command-invocation --region "$AWS_REGION" \
        --command-id "$cmd_id" --instance-id "$id" \
        --query Status --output text 2>/dev/null || echo Pending)"
      case "$status" in
        Pending|InProgress|Delayed) sleep 10 ;;
        *) break ;;
      esac
    done
    echo "--- [$desc] Output from $id ($status) ---"
    aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$cmd_id" --instance-id "$id" \
      --query StandardOutputContent --output text
    if [ "$status" != "Success" ]; then
      aws ssm get-command-invocation --region "$AWS_REGION" \
        --command-id "$cmd_id" --instance-id "$id" \
        --query StandardErrorContent --output text >&2
      echo "SSM step '$desc' failed on $id ($status)" >&2
      exit 1
    fi
  done
}

S3_PREFIX="s3://${ARTIFACT_BUCKET}/releases/k8s/${RELEASE}"

echo "== 1. Importing container images (ui, api, mysql:8.0) into containerd on all nodes =="
IMPORT_IMAGES_SCRIPT="$(cat <<EOF
set -euo pipefail
RELEASE_DIR="/opt/fde-task-app/releases/${RELEASE}"
mkdir -p "\$RELEASE_DIR"
aws s3 cp "${S3_PREFIX}/images.tar.gz" "\$RELEASE_DIR/images.tar.gz" --region "${AWS_REGION}"
aws s3 cp "${S3_PREFIX}/SHA256SUMS" "\$RELEASE_DIR/SHA256SUMS" --region "${AWS_REGION}"
(cd "\$RELEASE_DIR" && sha256sum -c SHA256SUMS)
gunzip -c "\$RELEASE_DIR/images.tar.gz" | ctr -n k8s.io images import -
rm -f "\$RELEASE_DIR/images.tar.gz"
ctr -n k8s.io images ls -q | grep -E 'fde-task|mysql'
EOF
)"
run_ssm_script "Import container images into containerd on all nodes" "$IMPORT_IMAGES_SCRIPT" "${ALL_IDS[@]}"

echo "== 2. Creating 3 Namespaces (db, api, ui) and deploying containers on Control Plane =="
DEPLOY_MANIFESTS_SCRIPT="$(cat <<EOF
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
RELEASE_DIR="/opt/fde-task-app/releases/${RELEASE}"
mkdir -p "\$RELEASE_DIR/k8s" "\$RELEASE_DIR/db"

aws s3 cp "${S3_PREFIX}/k8s/" "\$RELEASE_DIR/k8s/" --recursive --region "${AWS_REGION}"
aws s3 cp "${S3_PREFIX}/db/init.sql" "\$RELEASE_DIR/db/init.sql" --region "${AWS_REGION}"

DB_PASSWORD="\$(aws ssm get-parameter --name '${K8S_DB_PASSWORD_PARAM}' --with-decryption --region '${AWS_REGION}' --query Parameter.Value --output text)"
DB_ROOT_PASSWORD="\$(aws ssm get-parameter --name '${K8S_DB_ROOT_PASSWORD_PARAM}' --with-decryption --region '${AWS_REGION}' --query Parameter.Value --output text)"

echo "--- Creating 3 Namespaces: db, api, ui ---"
kubectl apply -f "\$RELEASE_DIR/k8s/namespaces.yaml"
kubectl get namespaces db api ui

echo "--- Deploying DB container in namespace 'db' ---"
kubectl apply -f "\$RELEASE_DIR/k8s/db.yaml"
kubectl -n db create secret generic db-credentials \
  --from-literal=db-password="\$DB_PASSWORD" \
  --from-literal=db-root-password="\$DB_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n db rollout status deployment/db --timeout=180s

echo "--- Deploying API container in namespace 'api' ---"
sed "s/fde-task-api:v1/fde-task-api:${RELEASE}/g" "\$RELEASE_DIR/k8s/api.yaml" | kubectl apply -f -
kubectl -n api create secret generic db-credentials \
  --from-literal=db-password="\$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASSWORD DB_ROOT_PASSWORD
kubectl -n api rollout status deployment/api --timeout=180s

echo "--- Deploying UI container in namespace 'ui' ---"
sed "s/fde-task-ui:v1/fde-task-ui:${RELEASE}/g" "\$RELEASE_DIR/k8s/ui.yaml" | kubectl apply -f -
kubectl -n ui rollout status deployment/ui --timeout=180s

echo "=== Kubernetes Nodes ==="
kubectl get nodes -o wide

echo "=== Namespace: db ==="
kubectl get pods,svc -n db -o wide

echo "=== Namespace: api ==="
kubectl get pods,svc -n api -o wide

echo "=== Namespace: ui ==="
kubectl get pods,svc -n ui -o wide

echo "=== Smoke Testing UI & API via NodePort ${K8S_NODEPORT} ==="
for attempt in \$(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${K8S_NODEPORT}/api/health" >/dev/null; then
    break
  fi
  if [ "\$attempt" -eq 30 ]; then
    echo "API health check via UI NodePort failed" >&2
    exit 1
  fi
  sleep 2
done
curl --fail --silent "http://127.0.0.1:${K8S_NODEPORT}/" >/dev/null
curl --fail --silent "http://127.0.0.1:${K8S_NODEPORT}/api/health"
echo
EOF
)"
run_ssm_script "Deploy 3 namespaces and 3 containers to Kubernetes" "$DEPLOY_MANIFESTS_SCRIPT" "$CP_ID"

CP_PUBLIC_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$CP_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
W1_PUBLIC_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "${WORKER_IDS[0]}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
W2_PUBLIC_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "${WORKER_IDS[1]}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "=================================================================="
echo "Kubernetes release $RELEASE is live across the 3-node cluster!"
echo "  Control Plane URL : http://${CP_PUBLIC_IP}:${K8S_NODEPORT}/  (or http://${CP_PUBLIC_IP}/)"
echo "  Worker 1 URL      : http://${W1_PUBLIC_IP}:${K8S_NODEPORT}/  (or http://${W1_PUBLIC_IP}/)"
echo "  Worker 2 URL      : http://${W2_PUBLIC_IP}:${K8S_NODEPORT}/  (or http://${W2_PUBLIC_IP}/)"
echo "=================================================================="

