#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"
: "${DOCKER_INSTANCE_TYPE:=t3.medium}"

ensure_secure_parameter() {
  local name=$1 value parameter_type
  if parameter_type="$(aws ssm get-parameter --name "$name" --region "$AWS_REGION" \
    --query 'Parameter.Type' --output text 2>/dev/null)"; then
    if [ "$parameter_type" != "SecureString" ]; then
      echo "Database parameter $name must be a SecureString, found $parameter_type" >&2
      return 1
    fi
    echo "Using existing SecureString parameter $name"
    return
  fi

  value="$(openssl rand -hex 32)"
  aws ssm put-parameter --name "$name" --type SecureString \
    --value "$value" --region "$AWS_REGION" >/dev/null
  unset value
  echo "Created SecureString parameter $name"
}

echo "== Ensuring runtime database credentials in Parameter Store =="
ensure_secure_parameter "$DOCKER_DB_PASSWORD_PARAM"
ensure_secure_parameter "$DOCKER_DB_ROOT_PASSWORD_PARAM"

echo "== Ensuring EC2 instance profile and least-scope parameter access =="
if ! aws iam get-role --role-name "$DOCKER_EC2_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$DOCKER_EC2_ROLE" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  sleep 10
fi

if ! aws iam get-instance-profile --instance-profile-name "$DOCKER_EC2_INSTANCE_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$DOCKER_EC2_INSTANCE_PROFILE" >/dev/null
fi
PROFILE_ROLE="$(aws iam get-instance-profile --instance-profile-name "$DOCKER_EC2_INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)"
if [ "$PROFILE_ROLE" = "None" ]; then
  aws iam add-role-to-instance-profile --instance-profile-name "$DOCKER_EC2_INSTANCE_PROFILE" \
    --role-name "$DOCKER_EC2_ROLE" >/dev/null
  sleep 10
elif [ "$PROFILE_ROLE" != "$DOCKER_EC2_ROLE" ]; then
  echo "Instance profile $DOCKER_EC2_INSTANCE_PROFILE is associated with unexpected role $PROFILE_ROLE" >&2
  exit 1
fi

aws iam attach-role-policy --role-name "$DOCKER_EC2_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
DOCKER_RUNTIME_POLICY="$(printf \
  '{"Version":"2012-10-17","Statement":[{"Sid":"ReadDatabaseCredentials","Effect":"Allow","Action":"ssm:GetParameter","Resource":["arn:aws:ssm:%s:%s:parameter%s","arn:aws:ssm:%s:%s:parameter%s"]},{"Sid":"ReadDockerReleaseObjects","Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::%s/releases/docker/*"}]}' \
  "$AWS_REGION" "$ACCOUNT_ID" "$DOCKER_DB_PASSWORD_PARAM" \
  "$AWS_REGION" "$ACCOUNT_ID" "$DOCKER_DB_ROOT_PASSWORD_PARAM" "$ARTIFACT_BUCKET")"
aws iam put-role-policy --role-name "$DOCKER_EC2_ROLE" \
  --policy-name "${APP_NAME}-docker-runtime" \
  --policy-document "$DOCKER_RUNTIME_POLICY"

echo "== Resolving VPC and subnet =="
VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}"
[ "$VPC_ID" != "None" ] || { echo "No default VPC; set VPC_ID and SUBNET_ID" >&2; exit 1; }
SUBNET_ID="${SUBNET_ID:-$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" Name=default-for-az,Values=true \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}"
[ "$SUBNET_ID" != "None" ] || { echo "No default subnet; set SUBNET_ID" >&2; exit 1; }

SG_NAME="${APP_NAME}-container-sg"
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ "$SG_ID" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "FDE Docker host - HTTP only" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=App,Value=$APP_NAME},{Key=Name,Value=$SG_NAME}]" \
    --query GroupId --output text)"
fi

INGRESS_CIDR="${UI_ALLOWED_CIDR:-0.0.0.0/0}"
INGRESS_ERROR="$(mktemp)"
if ! aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$INGRESS_CIDR}]" \
  >/dev/null 2>"$INGRESS_ERROR"; then
  if ! grep -q 'InvalidPermission.Duplicate' "$INGRESS_ERROR"; then
    cat "$INGRESS_ERROR" >&2
    rm -f "$INGRESS_ERROR"
    exit 1
  fi
fi
rm -f "$INGRESS_ERROR"

AMI_ID="$(aws ssm get-parameter --region "$AWS_REGION" --name "$UBUNTU_AMI_PARAM" \
  --query Parameter.Value --output text)"

user_data() {
  cat <<'EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io docker-compose-v2 curl unzip ca-certificates
systemctl enable --now docker
EOF
}

echo "== Provisioning separate Docker EC2 instance =="
INSTANCE_ID="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:App,Values=$APP_NAME" Name=tag:Role,Values=container \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text | head -1)"
if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  INSTANCE_STATE="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)"
  if [ "$INSTANCE_STATE" = "stopped" ]; then
    aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  fi
  echo "Reusing container instance $INSTANCE_ID ($INSTANCE_STATE)"
else
  INSTANCE_ID="$(aws ec2 run-instances --region "$AWS_REGION" \
    --image-id "$AMI_ID" --instance-type "$DOCKER_INSTANCE_TYPE" --count 1 \
    --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --iam-instance-profile "Name=$DOCKER_EC2_INSTANCE_PROFILE" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,Encrypted=true}" \
    --user-data "$(user_data)" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$APP_NAME-container},{Key=App,Value=$APP_NAME},{Key=Role,Value=container}]" \
      "ResourceType=volume,Tags=[{Key=App,Value=$APP_NAME},{Key=Role,Value=container}]" \
    --query 'Instances[0].InstanceId' --output text)"
fi

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
echo "Waiting for SSM agent and Docker bootstrap on $INSTANCE_ID"
for attempt in $(seq 1 90); do
  PING_STATUS="$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text)"
  if [ "$PING_STATUS" = "Online" ]; then
    echo "SSM is online"
    break
  fi
  if [ "$attempt" -eq 90 ]; then
    echo "Instance did not register with SSM; check its instance profile and network access" >&2
    exit 1
  fi
  sleep 10
done

aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress,PublicIpAddress]' --output table
