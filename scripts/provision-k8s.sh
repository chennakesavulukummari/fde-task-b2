#!/usr/bin/env bash
# Provision 3 Ubuntu 24.04 EC2 instances (1 Control Plane + 2 Worker Nodes),
# install containerd + kubeadm + kubelet + kubectl, initialize the Kubernetes cluster,
# install Flannel CNI, and join both worker nodes via AWS CLI + SSM.
set -euo pipefail

source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

ensure_secure_parameter() {
  local name=$1 value parameter_type
  if parameter_type="$(aws ssm get-parameter --name "$name" --region "$AWS_REGION" \
    --query 'Parameter.Type' --output text 2>/dev/null)"; then
    echo "Using existing parameter $name ($parameter_type)"
    return
  fi

  value="$(openssl rand -hex 24)"
  aws ssm put-parameter --name "$name" --type SecureString \
    --value "$value" --region "$AWS_REGION" >/dev/null
  unset value
  echo "Created SecureString parameter $name"
}

echo "== 1. Ensuring database credentials in SSM Parameter Store =="
ensure_secure_parameter "$K8S_DB_PASSWORD_PARAM"
ensure_secure_parameter "$K8S_DB_ROOT_PASSWORD_PARAM"

echo "== 2. Ensuring EC2 IAM role and instance profile ($K8S_EC2_INSTANCE_PROFILE) =="
if ! aws iam get-role --role-name "$K8S_EC2_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$K8S_EC2_ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  sleep 10
fi

if ! aws iam get-instance-profile --instance-profile-name "$K8S_EC2_INSTANCE_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$K8S_EC2_INSTANCE_PROFILE" >/dev/null
fi

PROFILE_ROLE="$(aws iam get-instance-profile --instance-profile-name "$K8S_EC2_INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)"
if [ "$PROFILE_ROLE" = "None" ]; then
  aws iam add-role-to-instance-profile --instance-profile-name "$K8S_EC2_INSTANCE_PROFILE" \
    --role-name "$K8S_EC2_ROLE" >/dev/null
  sleep 10
fi

aws iam attach-role-policy --role-name "$K8S_EC2_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
K8S_RUNTIME_POLICY="$(printf \
  '{"Version":"2012-10-17","Statement":[{"Sid":"ReadDatabaseCredentials","Effect":"Allow","Action":"ssm:GetParameter","Resource":["arn:aws:ssm:%s:%s:parameter%s","arn:aws:ssm:%s:%s:parameter%s"]},{"Sid":"ReadK8sReleaseObjects","Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"]}]}' \
  "$AWS_REGION" "$ACCOUNT_ID" "$K8S_DB_PASSWORD_PARAM" \
  "$AWS_REGION" "$ACCOUNT_ID" "$K8S_DB_ROOT_PASSWORD_PARAM" \
  "$ARTIFACT_BUCKET" "$ARTIFACT_BUCKET")"
aws iam put-role-policy --role-name "$K8S_EC2_ROLE" \
  --policy-name "${APP_NAME}-k8s-runtime" \
  --policy-document "$K8S_RUNTIME_POLICY"

echo "== 3. Resolving VPC, subnet, and Security Group =="
VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}"
[ "$VPC_ID" != "None" ] || { echo "No default VPC; set VPC_ID and SUBNET_ID" >&2; exit 1; }
SUBNET_ID="${SUBNET_ID:-$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" Name=default-for-az,Values=true \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}"
[ "$SUBNET_ID" != "None" ] || { echo "No default subnet; set SUBNET_ID" >&2; exit 1; }

SG_NAME="${APP_NAME}-k8s-sg"
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ "$SG_ID" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "FDE Kubernetes Cluster SG - Intra-cluster + HTTP 80 & NodePort 30080" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=App,Value=$APP_NAME},{Key=Name,Value=$SG_NAME}]" \
    --query GroupId --output text)"
fi

INGRESS_CIDR="${UI_ALLOWED_CIDR:-0.0.0.0/0}"
# Allow all intra-cluster traffic between the 3 Kubernetes nodes (API 6443, etcd, kubelet, Flannel VXLAN)
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$SG_ID}]" >/dev/null 2>&1 || true
# Allow HTTP 80 and NodePort 30080 from internet
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$INGRESS_CIDR}]" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=${K8S_NODEPORT},ToPort=${K8S_NODEPORT},IpRanges=[{CidrIp=$INGRESS_CIDR}]" >/dev/null 2>&1 || true

AMI_ID="$(aws ssm get-parameter --region "$AWS_REGION" --name "$UBUNTU_AMI_PARAM" \
  --query Parameter.Value --output text)"

ensure_k8s_node() {  # node_name role instance_type -> prints instance_id
  local node_name=$1 role=$2 itype=$3 id state
  id="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:App,Values=$APP_NAME" "Name=tag:Name,Values=$node_name" \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text | head -1)"
  if [ -n "$id" ] && [ "$id" != "None" ]; then
    state="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].State.Name' --output text)"
    if [ "$state" = "stopped" ]; then
      aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$id" >/dev/null
    fi
    echo "  Reusing $node_name: $id ($state)" >&2
  else
    id="$(aws ec2 run-instances --region "$AWS_REGION" \
      --image-id "$AMI_ID" --instance-type "$itype" --count 1 \
      --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
      --associate-public-ip-address \
      --iam-instance-profile "Name=$K8S_EC2_INSTANCE_PROFILE" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,Encrypted=true}" \
      --user-data "#!/bin/bash
hostnamectl set-hostname $node_name
" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$node_name},{Key=App,Value=$APP_NAME},{Key=Role,Value=$role},{Key=Cluster,Value=${APP_NAME}-k8s}]" \
        "ResourceType=volume,Tags=[{Key=App,Value=$APP_NAME},{Key=Role,Value=$role}]" \
      --query 'Instances[0].InstanceId' --output text)"
    echo "  Launched $node_name: $id ($itype)" >&2
  fi
  echo "$id"
}

echo "== 4. Provisioning 3 EC2 Instances (1 Control Plane + 2 Workers) =="
CP_ID="$(ensure_k8s_node "${APP_NAME}-k8s-cp" "k8s-control-plane" "$K8S_CP_INSTANCE_TYPE")"
W1_ID="$(ensure_k8s_node "${APP_NAME}-k8s-worker-1" "k8s-worker" "$K8S_WORKER_INSTANCE_TYPE")"
W2_ID="$(ensure_k8s_node "${APP_NAME}-k8s-worker-2" "k8s-worker" "$K8S_WORKER_INSTANCE_TYPE")"
ALL_IDS=("$CP_ID" "$W1_ID" "$W2_ID")

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "${ALL_IDS[@]}"
echo "All 3 instances running. Waiting for SSM agent registration..."

for id in "${ALL_IDS[@]}"; do
  for attempt in $(seq 1 90); do
    ping_status="$(aws ssm describe-instance-information --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"
    if [ "$ping_status" = "Online" ]; then
      echo "  $id: SSM Online"
      break
    fi
    if [ "$attempt" -eq 90 ]; then
      echo "Instance $id did not register with SSM" >&2
      exit 1
    fi
    sleep 10
  done
done

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

echo "== 5. Installing containerd, kubeadm, kubelet, kubectl (v${K8S_VERSION}) on all 3 nodes =="
NODE_PREP_SCRIPT="$(cat <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null 2>&1 || true; fi
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat > /etc/modules-load.d/k8s.conf <<'MOD'
overlay
br_netfilter
MOD
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<'SYS'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sysctl --system >/dev/null

apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 install -y apt-transport-https ca-certificates curl gpg containerd conntrack socat unzip iptables

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

if ! command -v kubeadm >/dev/null 2>&1; then
  mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  apt-get -o DPkg::Lock::Timeout=300 update -y
  apt-get -o DPkg::Lock::Timeout=300 install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet
fi

if ! command -v aws >/dev/null 2>&1; then
  arch="\$(uname -m)"
  workdir="\$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-\${arch}.zip" -o "\$workdir/awscliv2.zip"
  unzip -q "\$workdir/awscliv2.zip" -d "\$workdir"
  "\$workdir/aws/install" --update
  rm -rf "\$workdir"
fi

# Forward port 80 to NodePort ${K8S_NODEPORT} so both :80 and :${K8S_NODEPORT} reach the UI
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port ${K8S_NODEPORT} 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port ${K8S_NODEPORT}

echo "Node \$(hostname) ready with \$(kubeadm version -o short)"
EOF
)"
run_ssm_script "Install K8s prerequisites on all 3 nodes" "$NODE_PREP_SCRIPT" "${ALL_IDS[@]}"

CP_PRIVATE_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$CP_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

echo "== 6. Initializing Kubernetes Control Plane on $CP_ID ($CP_PRIVATE_IP) =="
CP_INIT_SCRIPT="$(cat <<EOF
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

if [ ! -f /etc/kubernetes/admin.conf ]; then
  kubeadm init \
    --apiserver-advertise-address="${CP_PRIVATE_IP}" \
    --pod-network-cidr="${K8S_POD_CIDR}" \
    --ignore-preflight-errors=NumCPU,Mem
fi

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown 0:0 /root/.kube/config

# Install Flannel CNI Pod network
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Save fresh join command for worker nodes
kubeadm token create --print-join-command > /tmp/kubeadm_join.sh
chmod 0700 /tmp/kubeadm_join.sh
EOF
)"
run_ssm_script "Initialize Kubernetes Control Plane" "$CP_INIT_SCRIPT" "$CP_ID"

echo "== 7. Fetching join command from Control Plane and joining 2 Worker Nodes =="
JOIN_CMD_ID="$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$CP_ID" --document-name AWS-RunShellScript \
  --comment "Read kubeadm join command" \
  --parameters 'commands=["cat /tmp/kubeadm_join.sh"]' \
  --query Command.CommandId --output text)"
for attempt in $(seq 1 30); do
  st="$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$JOIN_CMD_ID" --instance-id "$CP_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$st" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
done
JOIN_COMMAND="$(aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$JOIN_CMD_ID" --instance-id "$CP_ID" \
  --query StandardOutputContent --output text | tr -d '\r' | tail -n 1)"

if [[ "$JOIN_COMMAND" != kubeadm\ join* ]]; then
  echo "Failed to retrieve valid kubeadm join command: $JOIN_COMMAND" >&2
  exit 1
fi

WORKER_JOIN_SCRIPT="$(cat <<EOF
set -euo pipefail
if [ ! -f /etc/kubernetes/kubelet.conf ]; then
  ${JOIN_COMMAND}
fi
echo "Worker \$(hostname) joined cluster"
EOF
)"
run_ssm_script "Join 2 Worker Nodes to Kubernetes Cluster" "$WORKER_JOIN_SCRIPT" "$W1_ID" "$W2_ID"

echo "== 8. Waiting for all 3 Kubernetes nodes (1 Control Plane + 2 Workers) to be Ready =="
WAIT_NODES_SCRIPT="$(cat <<'EOF'
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
for attempt in $(seq 1 60); do
  ready_count=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {count++} END {print count+0}')
  if [ "$ready_count" -ge 3 ]; then
    kubectl get nodes -o wide
    exit 0
  fi
  sleep 5
done
kubectl get nodes -o wide
echo "Timed out waiting for all 3 nodes to become Ready" >&2
exit 1
EOF
)"
run_ssm_script "Wait for 3 Ready Kubernetes nodes" "$WAIT_NODES_SCRIPT" "$CP_ID"

echo "== 9. Cluster EC2 Instances Summary =="
aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "${ALL_IDS[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,Tags[?Key==`Role`]|[0].Value,InstanceId,PrivateIpAddress,PublicIpAddress]' \
  --output table

