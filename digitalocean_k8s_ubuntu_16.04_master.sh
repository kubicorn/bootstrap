# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use.
KUBERNETES_VERSION="1.11.1"
KUBERNETES_CNI="0.6.0"
DOCKER_VERSION="17.03"

# Obtain Droplet IP addresses.
HOSTNAME=$(curl -s http://169.254.169.254/metadata/v1/hostname)
PRIVATEIP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
PUBLICIP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
echo $PRIVATEIP > /tmp/.ip

# Add Kubernetes repository.
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
touch /etc/apt/sources.list.d/kubernetes.list
sh -c 'echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list'

# Add Docker repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sh -c 'echo "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list'

# Update apt cache
apt-get update -y

# Get docker version
pkg_pattern="$(echo "$DOCKER_VERSION" | sed "s/-ce-/~ce~/g" | sed "s/-/.*/g").*-0~ubuntu"
search_command="apt-cache madison 'docker-ce' | grep '$pkg_pattern' | head -1 | cut -d' ' -f 4"
pkg_version="$(sh -c "$search_command")"

# Install packages.
apt-get install -y \
    socat \
    ebtables \
    docker-ce="${pkg_version}" \
    apt-transport-https \
    kubelet=${KUBERNETES_VERSION}-00 \
    kubeadm=${KUBERNETES_VERSION}-00 \
    kubernetes-cni=${KUBERNETES_CNI}-00 \
    cloud-utils \
    jq

# Enable and start Docker.
systemctl enable docker
systemctl start docker

# Specify node IP for kubelet.
echo "Environment=\"KUBELET_EXTRA_ARGS=--node-ip=${PUBLICIP}\"" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
systemctl daemon-reload
systemctl restart kubelet

# Parse kubicorn configuration file.
TOKEN=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDTOKEN')
PORT=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDPORT | tonumber')

# Create kubeadm configuration file.
touch /etc/kubicorn/kubeadm-config.yaml
cat << EOF  > "/etc/kubicorn/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
token: ${TOKEN}
kubernetesVersion: ${KUBERNETES_VERSION}
nodeName: ${HOSTNAME}
api:
  advertiseAddress: ${PUBLICIP}
  bindPort: ${PORT}
apiServerCertSANs:
- ${PRIVATEIP}
- ${PUBLICIP}
- ${HOSTNAME}
authorizationModes:
- Node
- RBAC
EOF

# Initialize cluster.
kubeadm reset --force
kubeadm init --config /etc/kubicorn/kubeadm-config.yaml

# Weave CNI plugin.
curl -SL "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')&env.IPALLOC_RANGE=172.16.0.0/16" \
| kubectl apply --kubeconfig /etc/kubernetes/admin.conf -f -

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown -R root:root /root/.kube
