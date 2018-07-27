# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use.
KUBERNETES_VERSION="1.11.1"
KUBERNETES_CNI="0.6.0"
DOCKER_VERSION="17.03"

# Controls delay before attempting to join the master
MAX_ATTEMPTS=50
REATTEMPT_INTERVAL_SECONDS=30

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
MASTER=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDMASTER')

# Join node a cluster.
kubeadm reset --force

# Delay kubeadm join until master is ready
attempts=0
response=000
while [ "${response}" -ne "200" ] && [ $(( attempts++ )) -lt $MAX_ATTEMPTS ]; do
  echo "Waiting for master to be ready(${MASTER})..."
  sleep $REATTEMPT_INTERVAL_SECONDS
  response=$(curl --write-out "%{http_code}" --output /dev/null --silent --connect-timeout 10 -k "https://${MASTER}/healthz" || true)
done

if [ "${response}" -ne "200" ]; then
  echo "Maximum attempts reached, giving up"
  exit 1
else
  echo "Master seems to be up and running. Joining it..."
  kubeadm join --node-name "${HOSTNAME}" --token "${TOKEN}" "${MASTER}" --discovery-token-unsafe-skip-ca-verification
fi
