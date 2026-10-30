#!/usr/bin/env bash
# Tear down the EC2 instances and security groups (keeps repo, bucket, IAM, CodeBuild).
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

# Delete in dependency order (ui-sg is referenced by api-sg, api-sg by db-sg).
for role in db api ui; do
  SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$APP_NAME-$role-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" && echo "Deleted $SG"
done
echo "Done."
