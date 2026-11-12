# Architecture Notes — 3-Node Kubernetes Cluster on EC2 (`k8s-ec2-deployment`)

This branch provisions **3 Ubuntu 24.04 EC2 instances** (**1 Control Plane** + **2 Worker Nodes**) in AWS (`ap-south-2`), bootstraps a **Kubernetes (`kubeadm` v1.31 + `containerd` + Flannel CNI)** cluster via AWS CodeBuild and AWS Systems Manager (SSM), creates **3 Kubernetes Namespaces (`ui`, `api`, `db`)**, and deploys the **3 Docker containers (`ui`, `api`, `db`)** across the cluster.

---

## 1. Mermaid Diagram: End-to-End CI/CD + 3-Node Kubernetes Architecture

```mermaid
flowchart TB
    subgraph Source["1. Source Repository"]
        GIT["Git Repository (fde-task-app)<br/>Branch: k8s-ec2-deployment<br/>ui/ · api/ · db/ · k8s/ · scripts/ · buildspecs/"]
    end

    subgraph CI["2. AWS CodeBuild - CI Image Build"]
        CB_IMG["CodeBuild Job 1: Image Build<br/>(buildspecs/buildspec-k8s-images.yml)<br/>Runs: scripts/build-k8s-images.sh"]
    end

    subgraph AWS_Store["3. Artifact Store & Secrets"]
        S3[("Amazon S3 Bucket (s3://fde-artifacts)<br/>releases/k8s/&lt;version&gt;/images.tar.gz<br/>k8s/*.yaml · db/init.sql · SHA256SUMS")]
        SSM_PARAM["AWS SSM Parameter Store<br/>Ubuntu 24.04 AMI ID<br/>/fde-task-app/k8s/db-password<br/>/fde-task-app/k8s/db-root-password"]
    end

    subgraph CD["4. AWS CodeBuild - Cluster Provision & App Deploy"]
        CB_DEPLOY["CodeBuild Job 2: Provision & Deploy<br/>(buildspecs/buildspec-k8s-deploy.yml)<br/>Step 1: scripts/provision-k8s.sh<br/>Step 2: scripts/deploy-k8s.sh"]
        SSM_RUN["AWS Systems Manager<br/>SSM Run Command (No SSH / Port 22)"]
    end

    subgraph VPC["5. AWS Region ap-south-2 (Default VPC) | Security Group: fde-task-app-k8s-sg (:80, :30080, Intra-Cluster)"]
        USER(("Browser / Internet User"))

        subgraph K8S["3-Node Kubernetes Cluster (kubeadm v1.31 + containerd + Flannel CNI 10.244.0.0/16)"]
            subgraph CP["EC2 Node 1: Control Plane (fde-task-app-k8s-cp | Ubuntu 24.04 t3.medium)"]
                API_SRV["kube-apiserver (:6443) · etcd · kube-scheduler · kube-controller-manager"]
            end

            subgraph WORKERS["EC2 Nodes 2 & 3: Worker Nodes (fde-task-app-k8s-worker-1 & worker-2 | Ubuntu 24.04 t3.medium)"]
                subgraph NS_UI["Namespace: ui"]
                    SVC_UI["Service: ui (NodePort 30080 / Host :80)"]
                    POD_UI["Deployment: ui (2 Replicas)<br/>Container: fde-task-ui (Nginx :8080)"]
                    EXT_API["Service: api (ExternalName)<br/>-> api.api.svc.cluster.local"]
                end

                subgraph NS_API["Namespace: api"]
                    SVC_API["Service: api (ClusterIP :8000)"]
                    POD_API["Deployment: api (2 Replicas)<br/>Container: fde-task-api (FastAPI/Uvicorn :8000)"]
                    SEC_API["Secret: db-credentials"]
                end

                subgraph NS_DB["Namespace: db"]
                    SVC_DB["Service: db (ClusterIP :3306)"]
                    POD_DB[("Deployment: db (1 Replica)<br/>Container: mysql:8.0 (:3306)")]
                    CM_DB["ConfigMap: db-init-sql (db/init.sql)"]
                    SEC_DB["Secret: db-credentials"]
                end
            end
        end
    end

    GIT -->|"Trigger"| CB_IMG
    CB_IMG -->|"Upload images.tar.gz + k8s/*.yaml"| S3
    S3 -->|"Pull Release Bundle"| CB_DEPLOY
    SSM_PARAM -.->|"AMI ID & DB Credentials"| CB_DEPLOY
    CB_DEPLOY -->|"AWS CLI + SSM"| SSM_RUN
    SSM_RUN -->|"kubeadm init + kubectl apply"| CP
    SSM_RUN -->|"ctr images import + kubeadm join"| WORKERS
    API_SRV -.->|"Schedules Pods across 3 Namespaces"| WORKERS

    USER -->|"HTTP :80 or :30080"| SVC_UI
    SVC_UI --> POD_UI
    POD_UI -->|"Reverse Proxy /api/* & /docs"| EXT_API
    EXT_API -->|"Cross-Namespace DNS"| SVC_API
    SVC_API --> POD_API
    POD_API -->|"SQLAlchemy / PyMySQL<br/>db.db.svc.cluster.local:3306"| SVC_DB
    SVC_DB --> POD_DB
    CM_DB -.-> POD_DB
    SEC_DB -.-> POD_DB
    SEC_API -.-> POD_API
```

---

## 2. Mermaid Diagram: Execution Sequence Flow

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Operator / Dev
    participant CB1 as CodeBuild Job 1<br/>(buildspec-k8s-images.yml)
    participant S3 as Amazon S3<br/>(s3://fde-artifacts)
    participant CB2 as CodeBuild Job 2<br/>(buildspec-k8s-deploy.yml)
    participant EC2 as AWS EC2 & SSM<br/>(ap-south-2)
    participant CP as Node 1: Control Plane<br/>(fde-task-app-k8s-cp)
    participant WK as Nodes 2 & 3: Workers<br/>(worker-1 & worker-2)

    Dev->>CB1: 1. Start Build (scripts/build-k8s-images.sh)
    CB1->>CB1: Validate UI, API, DB & k8s/*.yaml
    CB1->>CB1: docker build fde-task-ui & fde-task-api + pull mysql:8.0
    CB1->>S3: Upload images.tar.gz, k8s/*.yaml, db/init.sql & k8s-LATEST

    Dev->>CB2: 2. Start Deploy (scripts/provision-k8s.sh + scripts/deploy-k8s.sh)
    CB2->>EC2: Ensure SSM DB Passwords, IAM Profile & Security Group (:80, :30080, Intra-SG)
    CB2->>EC2: Launch 3 Ubuntu 24.04 EC2 Instances (1 CP + 2 Workers)
    CB2->>CP: SSM: Install containerd, kubeadm, kubelet, kubectl (v1.31)
    CB2->>WK: SSM: Install containerd, kubeadm, kubelet, kubectl (v1.31)
    CB2->>CP: SSM: kubeadm init + Apply Flannel CNI + Generate Join Token
    CB2->>WK: SSM: kubeadm join (Worker 1 & Worker 2 join Control Plane)
    CB2->>CP: SSM: Verify all 3 Nodes are Ready

    CB2->>S3: Resolve k8s-LATEST release
    S3-->>CP: Download images.tar.gz -> ctr -n k8s.io images import
    S3-->>WK: Download images.tar.gz -> ctr -n k8s.io images import
    CB2->>CP: SSM: kubectl apply k8s/namespaces.yaml (Namespaces: db, api, ui)
    CB2->>CP: SSM: Create Secrets & ConfigMap + kubectl apply db.yaml, api.yaml, ui.yaml
    CP->>WK: Schedule & start db, api, and ui Pods across Worker Nodes
    CB2->>CP: Smoke test http://127.0.0.1:30080/ & /api/health
    CB2-->>Dev: Output Live Cluster URLs (http://<NODE_PUBLIC_IP>:30080/ and :80)
```

---

## 3. Lucidchart AI Prompt

Copy and paste the following prompt into Lucidchart’s **Generate diagram with AI**:

```text
Create a detailed AWS Cloud Architecture and CI/CD Pipeline diagram for the "FDE Task Tracker" 3-Node Kubernetes Cluster deployment on Amazon EC2 (branch: k8s-ec2-deployment) in AWS Region ap-south-2 (Hyderabad):

1. Source Control:
- Git Repository (fde-task-app, branch: k8s-ec2-deployment) containing ui/Dockerfile, api/Dockerfile, db/init.sql, k8s/ manifests (namespaces.yaml, db.yaml, api.yaml, ui.yaml), scripts/, and buildspecs/.

2. CI Container Build Pipeline (AWS CodeBuild Job 1 - buildspec-k8s-images.yml):
- Runs scripts/build-k8s-images.sh:
  - Validates UI (Node.js), API (Python 3.12 / FastAPI), DB schema (init.sql), and Kubernetes YAML manifests.
  - Builds Docker container images fde-task-ui:<version> and fde-task-api:<version>, and pulls mysql:8.0.
  - Exports all 3 container images into images.tar.gz, packages k8s/*.yaml and db/init.sql with SHA256SUMS, and uploads to Amazon S3 bucket "s3://fde-artifacts/releases/k8s/<version>/" (updating k8s-LATEST).

3. Secrets & Configuration (AWS SSM Parameter Store):
- Stores Ubuntu 24.04 LTS AMI ID and SecureString parameters /fde-task-app/k8s/db-password and /fde-task-app/k8s/db-root-password.

4. CD Cluster Provisioning & Application Deployment (AWS CodeBuild Job 2 - buildspec-k8s-deploy.yml):
- Step 1 (pre_build - scripts/provision-k8s.sh):
  - Uses AWS CLI to create IAM Instance Profile (fde-task-app-k8s-ec2-profile) and Security Group (fde-task-app-k8s-sg allowing Inbound HTTP Port 80, NodePort 30080 from Internet, and all internal traffic between cluster nodes).
  - Launches 3 Ubuntu 24.04 LTS EC2 instances (t3.medium):
    1) Control Plane Node: fde-task-app-k8s-cp (Role=k8s-control-plane)
    2) Worker Node 1: fde-task-app-k8s-worker-1 (Role=k8s-worker)
    3) Worker Node 2: fde-task-app-k8s-worker-2 (Role=k8s-worker)
  - Via AWS Systems Manager (SSM) Run Command (no SSH / Port 22), installs containerd, kubeadm, kubelet, and kubectl (v1.31) on all 3 nodes, runs "kubeadm init" on the Control Plane, installs Flannel CNI pod network (10.244.0.0/16), and joins Worker Node 1 and Worker Node 2 to the cluster.
- Step 2 (build - scripts/deploy-k8s.sh):
  - Pulls images.tar.gz from S3 onto all 3 nodes and imports the 3 container images into containerd (k8s.io namespace).
  - Applies Kubernetes manifests on the Control Plane to create 3 Namespaces and deploy 3 Containers across the Worker Nodes.

5. Kubernetes Cluster Workload Architecture (3 Namespaces on the Worker Nodes):
- Namespace 1: "ui"
  - Service "ui" (NodePort 30080, plus iptables redirect from Host Port 80 -> 30080).
  - Deployment "ui" (2 replicas running fde-task-ui Nginx container on port 8080, mounting ConfigMap ui-nginx-config).
  - ExternalName Service "api" pointing to api.api.svc.cluster.local.
- Namespace 2: "api"
  - Service "api" (ClusterIP port 8000).
  - Deployment "api" (2 replicas running fde-task-api FastAPI/Uvicorn container on port 8000, reading Secret db-credentials).
  - ExternalName Service "db" pointing to db.db.svc.cluster.local.
- Namespace 3: "db"
  - Service "db" (ClusterIP port 3306).
  - Deployment "db" (1 replica running mysql:8.0 container on port 3306, mounting ConfigMap db-init-sql for db/init.sql and Secret db-credentials).

Show two distinct flows:
- CI/CD & Management Flow: Git -> CodeBuild Job 1 -> S3 (fde-artifacts) -> CodeBuild Job 2 -> AWS SSM Run Command -> Control Plane & 2 Worker Nodes.
- User Request Traffic Flow: Internet User -> HTTP :80 / NodePort :30080 -> Namespace "ui" (Nginx Pod) -> Cross-Namespace DNS (api.api.svc.cluster.local:8000) -> Namespace "api" (FastAPI Pod) -> Cross-Namespace DNS (db.db.svc.cluster.local:3306) -> Namespace "db" (MySQL 8.0 Pod).
```
