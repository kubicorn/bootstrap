# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use
KUBERNETES_VERSION="1.10.11"
KUBERNETES_CNI="0.7.5"

# Controls delay before attempting to join the master
MAX_ATTEMPTS=50
REATTEMPT_INTERVAL_SECONDS=30

apt-get update -y
apt-get install -y \
    socat \
    cloud-utils \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    jq

curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo apt-key add -

add-apt-repository \
   "deb https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
   $(lsb_release -cs) \
   stable"

apt-get update && apt-get install -y docker-ce=$(apt-cache madison docker-ce | grep 17.03 | head -1 | awk '{print $3}')

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -

cat << EOF > "/etc/apt/sources.list.d/kubernetes.list"
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF

apt-get update -y
apt-get install -y \
	kubelet=${KUBERNETES_VERSION}-00 \
	kubeadm=${KUBERNETES_VERSION}-00 \
	kubernetes-cni=${KUBERNETES_CNI}-00 \
	kubectl

systemctl enable docker
systemctl start docker

TOKEN=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDTOKEN')
MASTER=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDMASTER')
HOSTNAME=$(hostname -f)


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
