# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use.
KUBERNETES_VERSION="1.14.1"
KUBERNETES_CNI="0.6.0"

# Controls delay before attempting to join the master
MAX_ATTEMPTS=50
REATTEMPT_INTERVAL_SECONDS=30


# Import GPG keys and add repository entries for Kuberenetes.
rpm --import https://packages.cloud.google.com/yum/doc/yum-key.gpg
rpm --import https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg

cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=http://yum.kubernetes.io/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

yum makecache -y
yum install -y \
     docker \
     socat \
     ebtables \
     kubelet-${KUBERNETES_VERSION}-0 \
     kubeadm-${KUBERNETES_VERSION}-0 \
     kubernetes-cni-${KUBERNETES_CNI}-0 \
     epel-release

# "jq" depends on epel-release, so it needs its own yum install command.
yum install -y jq

# Enable Docker and Kubelet services.
sudo systemctl enable docker
sudo systemctl enable kubelet
sudo systemctl start docker

# Required by kubeadm.
sysctl -w net.bridge.bridge-nf-call-iptables=1
sysctl -p

# Specify node IP for kubelet.
echo "KUBELET_EXTRA_ARGS=--node-ip=${PUBLICIP} --cloud-provider=external" > /etc/default/kubelet
systemctl daemon-reload
systemctl restart kubelet

# Parse kubicorn configuration file.
TOKEN=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDTOKEN')
MASTER=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDMASTER')

# Reset before joining
kubeadm reset

# Delay kubeadm join until master is ready
attempts=0
response=000
while [ "${response}" -ne "200" ] && [ $(( attempts++ )) -lt $MAX_ATTEMPTS ]; do
  echo "Waiting for master to be ready(${MASTER})..."
  sleep $REATTEMPT_INTERVAL_SECONDS
  response=$(curl --write-out "%{http_code}" --output /dev/null --silent --connect-timeout 10 -k "https://${MASTER}/healthz" || true)
done

# Join the cluster
if [ "${response}" -ne "200" ]; then
  echo "Maximum attempts reached, giving up"
  exit 1
else
  echo "Master seems to be up and running. Joining the node to the cluster..."
  kubeadm join --node-name "${HOSTNAME}" --token "${TOKEN}" "${MASTER}" --discovery-token-unsafe-skip-ca-verification --ignore-preflight-errors=SystemVerification
fi
