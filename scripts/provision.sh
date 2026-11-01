#!/usr/bin/env bash
# CodeBuild job: provision UI, API and/or DB EC2 instances (Ubuntu 24.04) with the AWS CLI.
# Idempotent: re-running reuses existing security groups and instances.
# Optional env: ROLE (all|ui|api|db, default: all)
set -euo pipefail
source "$(dirname "$0")/../config.env"

TARGET_ROLE="${ROLE:-all}"
TAG_FILTER="Name=tag:App,Values=$APP_NAME"

echo "== Ubuntu AMI =="
AMI_ID=$(aws ssm get-parameter --name "$UBUNTU_AMI_PARAM" --region "$AWS_REGION" --query Parameter.Value --output text)
echo "AMI: $AMI_ID ($AWS_REGION)"

echo "== Ensure DB Password in SSM Parameter Store =="
if ! aws ssm get-parameter --name "$DB_PASSWORD_PARAM" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ssm put-parameter --name "$DB_PASSWORD_PARAM" --type SecureString --value "FdeTaskPass123456" --region "$AWS_REGION" >/dev/null 2>&1 || true
fi

echo "== Ensure EC2 IAM Instance Profile ($EC2_INSTANCE_PROFILE) =="
if ! aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null 2>&1; then
  EC2_ROLE="${APP_NAME}-ec2-role"
  aws iam get-role --role-name "$EC2_ROLE" >/dev/null 2>&1 || \
    aws iam create-role --role-name "$EC2_ROLE" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null 2>&1 || true
  aws iam attach-role-policy --role-name "$EC2_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
  aws iam attach-role-policy --role-name "$EC2_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess >/dev/null 2>&1 || true
  aws iam create-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null 2>&1 || true
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" --role-name "$EC2_ROLE" >/dev/null 2>&1 || true
  sleep 10
fi

echo "== Network (default VPC unless VPC_ID/SUBNET_ID set) =="
VPC_ID=${VPC_ID:-$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)}
[ "$VPC_ID" = "None" ] && { echo "No default VPC; set VPC_ID and SUBNET_ID"; exit 1; }
SUBNET_ID=${SUBNET_ID:-$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}
echo "VPC: $VPC_ID  Subnet: $SUBNET_ID"

ensure_sg() {  # name description -> prints sg id
  local name=$1 desc=$2 id
  id=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$name" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ]; then
    id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" \
      --vpc-id "$VPC_ID" --query GroupId --output text \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=App,Value=$APP_NAME},{Key=Name,Value=$name}]")
  fi
  echo "$id"
}

allow() {  # sg-id port source(cidr|sg-id)
  local sg=$1 port=$2 src=$3 perm
  if [[ $src == sg-* ]]; then
    perm="IpProtocol=tcp,FromPort=$port,ToPort=$port,UserIdGroupPairs=[{GroupId=$src}]"
  else
    perm="IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=$src}]"
  fi
  aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions "$perm" \
    >/dev/null 2>&1 || true   # already exists
}

echo "== Security groups =="
UI_SG=$(ensure_sg  "$APP_NAME-ui-sg"  "FDE UI - HTTP from internet")
API_SG=$(ensure_sg "$APP_NAME-api-sg" "FDE API - 8000 from UI only")
DB_SG=$(ensure_sg  "$APP_NAME-db-sg"  "FDE DB - 3306 from API only")
allow "$UI_SG"  80   "${UI_ALLOWED_CIDR:-0.0.0.0/0}"
allow "$API_SG" 8000 "$UI_SG"
allow "$DB_SG"  3306 "$API_SG"
echo "UI=$UI_SG API=$API_SG DB=$DB_SG  (no SSH: access is via SSM Session Manager)"

user_data() {  # role -> base packages + utilities installed at first boot
  local pkgs
  case $1 in
    ui)  pkgs="nginx unzip curl" ;;
    api) pkgs="python3-venv python3-pip unzip curl" ;;
    db)  pkgs="mysql-server unzip curl" ;;
  esac
  cat <<EOF
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
hostnamectl set-hostname $APP_NAME-$1
apt-get update -y
apt-get install -y $pkgs
snap list aws-cli >/dev/null 2>&1 || snap install aws-cli --classic
EOF
}

ensure_instance() {  # role type sg -> prints instance id
  local role=$1 type=$2 sg=$3 id state
  read -r id state < <(aws ec2 describe-instances \
    --filters "$TAG_FILTER" "Name=tag:Role,Values=$role" \
              Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[0].[InstanceId,State.Name]' --output text | head -1) || true
  if [ -n "${id:-}" ] && [ "$id" != "None" ]; then
    [ "$state" = "stopped" ] && aws ec2 start-instances --instance-ids "$id" >/dev/null
    echo "  $role: reusing $id ($state)" >&2
  else
    id=$(aws ec2 run-instances \
      --image-id "$AMI_ID" --instance-type "$type" --count 1 \
      --subnet-id "$SUBNET_ID" --security-group-ids "$sg" \
      --associate-public-ip-address \
      --iam-instance-profile Name="$EC2_INSTANCE_PROFILE" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,Encrypted=true}" \
      --user-data "$(user_data "$role")" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$APP_NAME-$role},{Key=App,Value=$APP_NAME},{Key=Role,Value=$role}]" \
        "ResourceType=volume,Tags=[{Key=App,Value=$APP_NAME},{Key=Role,Value=$role}]" \
      --query 'Instances[0].InstanceId' --output text)
    echo "  $role: launched $id ($type)" >&2
  fi
  echo "$id"
}

echo "== Instances (ROLE=$TARGET_ROLE) =="
INSTANCE_IDS=()
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "db" ]; then
  DB_ID=$(ensure_instance db "$DB_INSTANCE_TYPE" "$DB_SG")
  INSTANCE_IDS+=("$DB_ID")
fi
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "api" ]; then
  API_ID=$(ensure_instance api "$API_INSTANCE_TYPE" "$API_SG")
  INSTANCE_IDS+=("$API_ID")
fi
if [ "$TARGET_ROLE" = "all" ] || [ "$TARGET_ROLE" = "ui" ]; then
  UI_ID=$(ensure_instance ui "$UI_INSTANCE_TYPE" "$UI_SG")
  INSTANCE_IDS+=("$UI_ID")
fi

aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}"
echo "Instance(s) running. Waiting for SSM agent registration..."

for id in "${INSTANCE_IDS[@]}"; do
  for i in $(seq 1 60); do
    s=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text)
    [ "$s" = "Online" ] && { echo "  $id: SSM Online"; break; }
    [ "$i" = 60 ] && { echo "  $id never registered with SSM (check instance profile / outbound internet)"; exit 1; }
    sleep 10
  done
done

echo "== Summary =="
aws ec2 describe-instances --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Role`]|[0].Value,InstanceId,InstanceType,PrivateIpAddress,PublicIpAddress]' \
  --output table
