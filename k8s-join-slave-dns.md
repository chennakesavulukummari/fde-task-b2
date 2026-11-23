
# Step 1: Run on the Primary Control-Plane Node

Run these commands on your existing Control-Plane (k8s-cp) machine to upload the cluster certificates and print the full Control-Plane join command:


CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -n 1)
JOIN_CMD=$(sudo kubeadm token create --print-join-command)
echo "sudo $JOIN_CMD --control-plane --certificate-key $CERT_KEY"

# Command output will look like this:

sudo kubeadm join 172.31.32.150:6443 --token 66ufr4.hq1q29rz20sahk8e --discovery-token-ca-cert-hash sha256:97fe47a80af91af8ca0737eebc32be6dc0ae58fe44baec584115238478df89bb --control-plane --certificate-key <CERT_KEY>

# Step 2: Run on the Secondary Control-Plane Node

Copy and run that output command on the new Control-Plane slave machine:

sudo kubeadm join <CP_PRIVATE_IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key <CERT_KEY>

# Then configure kubectl on the new Control-Plane node:

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Note: If you originally ran kubeadm init without --control-plane-endpoint, kubeadm will ask for controlPlaneEndpoint in the kubeadm-config ConfigMap before allowing a second control plane to join. If you see that warning, run this once on your primary Control-Plane node first (then re-run Step 1):

CP_IP=$(hostname -I | awk '{print $1}')
kubectl -n kube-system get configmap kubeadm-config -o yaml | \
   sed "s/clusterName: kubernetes/clusterName: kubernetes\n    controlPlaneEndpoint: ${CP_IP}:6443/" | \
  kubectl apply -f -