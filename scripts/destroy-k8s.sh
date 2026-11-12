#!/usr/bin/env bash
# Tear down the 3 Kubernetes EC2 instances (1 Control Plane + 2 Workers) and security group.
set -euo pipefail
source "$(dirname "$0")/../config.env"

IDS="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Cluster,Values=${APP_NAME}-k8s" \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)"

if [ -n "$IDS" ] && [ "$IDS" != "None" ]; then
  echo "Terminating Kubernetes cluster instances: $IDS"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $IDS >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $IDS
fi

SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${APP_NAME}-k8s-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID"
  echo "Deleted security group $SG_ID (${APP_NAME}-k8s-sg)"
fi
echo "Kubernetes cluster teardown complete."

