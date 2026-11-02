#!/usr/bin/env bash
# Tear down the EC2 instance(s) and security group(s) (keeps repo, bucket, IAM, CodeBuild).
set -euo pipefail
source "$(dirname "$0")/../config.env"

IDS=$(aws ec2 describe-instances --filters "Name=tag:App,Values=$APP_NAME" \
  Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  echo "Terminating: $IDS"
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

for sg_name in "$APP_NAME-sg" "$APP_NAME-db-sg" "$APP_NAME-api-sg" "$APP_NAME-ui-sg"; do
  SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$sg_name" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" && echo "Deleted $SG ($sg_name)"
done
echo "Done."
