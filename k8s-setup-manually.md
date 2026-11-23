# Manual Step-by-Step Kubernetes Setup on Ubuntu 26.04 LTS (1 Control Plane + 2 Worker Nodes)

## Prerequisites (AWS EC2 Security Group & Instances)
- **3 Ubuntu 26.04 LTS EC2 Instances** (`t3.medium` or larger — minimum 2 vCPU, 4 GB RAM):
  1. **Control Plane**: `k8s-cp`
  2. **Worker 1**: `k8s-worker-1`
  3. **Worker 2**: `k8s-worker-2`
- **Security Group Rules** (attach the same Security Group to all 3 instances):
  - **All Traffic (`All` protocol, `All` ports)**: Source = **Self** (the Security Group ID itself, for `6443`, `2379-2380`, `10250`, and Flannel UDP `8472`)
  - **SSH (`TCP 22`)**: Source = `0.0.0.0/0` (or your IP)
  - **HTTP (`TCP 80`)**: Source = `0.0.0.0/0`
  - **NodePort (`TCP 30080`)**: Source = `0.0.0.0/0`

---

## PART 1: Run on ALL 3 Nodes (`k8s-cp`, `k8s-worker-1`, `k8s-worker-2`)

### 1.1 Set Hostname on Each Node
On **Control Plane**:
```bash
sudo hostnamectl set-hostname k8s-cp
```
On **Worker 1**:
```bash
sudo hostnamectl set-hostname k8s-worker-1
```
On **Worker 2**:
```bash
sudo hostnamectl set-hostname k8s-worker-2
```

---

### 1.2 Disable Swap (All 3 Nodes)
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

---

### 1.3 Enable Kernel Modules & Networking Sysctl (All 3 Nodes)
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

---

### 1.4 Install & Configure `containerd` (All 3 Nodes)
```bash
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd conntrack socat

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd --no-pager
```

---

### 1.5 Install `kubeadm`, `kubelet`, and `kubectl` (All 3 Nodes)
```bash
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

---

## PART 2: Run ONLY on Control Plane Node (`k8s-cp`)

### 2.1 Initialize Kubernetes Control Plane
```bash
CP_PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo "Control Plane Private IP: $CP_PRIVATE_IP"

sudo kubeadm init \
  --apiserver-advertise-address="$CP_PRIVATE_IP" \
  --pod-network-cidr=10.244.0.0/16
```

---

### 2.2 Configure `kubectl` for Your User
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

### 2.3 Install Flannel CNI Pod Network
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

---

### 2.4 Print the Worker Join Command
```bash
kubeadm token create --print-join-command
```
*(Copy the printed `kubeadm join ...` command for the next step.)*

---

## PART 3: Run ONLY on Worker 1 (`k8s-worker-1`) & Worker 2 (`k8s-worker-2`)

### 3.1 Join Both Worker Nodes to the Cluster
Paste the `kubeadm join` command from Step 2.4 with `sudo` on **both Worker 1 and Worker 2**:
```bash
sudo kubeadm join <CP_PRIVATE_IP>:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

---

### 3.2 Verify All 3 Nodes Are `Ready` (Run on `k8s-cp`)
```bash
kubectl get nodes -o wide
```

---

## PART 4: Build & Import Container Images (`ui`, `api`, `db`)

If you are building locally on the nodes instead of pulling from a registry, run on **Worker 1 and Worker 2** (or build once on `k8s-cp` and copy `/tmp/images.tar.gz` to the workers):
```bash
sudo apt-get install -y docker.io git
sudo systemctl enable --now docker

git clone -b k8s-ec2-deployment https://github.com/chennakesavulukummari/fde-task-b2.git
cd fde-task-b2

sudo docker build -t docker.io/library/fde-task-api:v1 ./api
sudo docker build -t docker.io/library/fde-task-ui:v1 ./ui
sudo docker pull docker.io/library/mysql:8.0

sudo docker save \
  docker.io/library/fde-task-api:v1 \
  docker.io/library/fde-task-ui:v1 \
  docker.io/library/mysql:8.0 | sudo ctr -n k8s.io images import -

sudo ctr -n k8s.io images ls -q | grep -E 'fde-task|mysql'
```

---

## PART 5: Create 3 Namespaces (`db`, `api`, `ui`) & Deploy 3 Containers Using YAML Files (Run on `k8s-cp`)

```bash
cd ~/fde-task-b2

# Step 1: Create the 3 namespaces (db, api, ui)
kubectl apply -f k8s/namespaces.yaml
kubectl get namespaces

# Step 2: Deploy DB Container, Secret & ConfigMap in namespace 'db'
kubectl apply -f k8s/db.yaml
kubectl -n db rollout status deployment/db --timeout=180s
kubectl get pods,svc -n db -o wide

# Step 3: Deploy API Container, Secret & Service in namespace 'api'
kubectl apply -f k8s/api.yaml
kubectl -n api rollout status deployment/api --timeout=180s
kubectl get pods,svc -n api -o wide

# Step 4: Deploy UI Container, ConfigMap & NodePort Service in namespace 'ui'
kubectl apply -f k8s/ui.yaml
kubectl -n ui rollout status deployment/ui --timeout=180s
kubectl get pods,svc -n ui -o wide

# Step 5: Verify all resources across the 3 namespaces
kubectl get all -n db
kubectl get all -n api
kubectl get all -n ui

# Step 6: Test UI and API via NodePort 30080
curl -i http://127.0.0.1:30080/
curl -i http://127.0.0.1:30080/api/health
```

---

## PART 6: Access in Browser
Open any of the 3 node public IPs on NodePort `30080`:
- `http://<CONTROL_PLANE_PUBLIC_IP>:30080/`
- `http://<WORKER_1_PUBLIC_IP>:30080/`
- `http://<WORKER_2_PUBLIC_IP>:30080/`
- Swagger API Docs: `http://<NODE_PUBLIC_IP>:30080/docs`

