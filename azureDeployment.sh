#!/bin/bash

set -o errexit
set -x

readonly LOG_FILE="/var/log/kineticak8_az_deployment.log"
sudo touch $LOG_FILE
exec 1> >(tee -a $LOG_FILE)
exec 2>&1 

export KUBECONFIG=/root/.kube/config

echo $@
function print_usage() {
  cat <<EOF
Auto Loads AKS cluster with kinetica operator (login and cli are disabled)
Command
  $0
Arguments
  --aks_name|-an                      : The name of the AKS cluster to connect to
  --auth_type|-at                     : Whether the identity is Managed or SP(Service Principal)
  --client_id|-clid                   : The service principal ID.
  --client_secret|-clis               : The service principal secret.
  --subscription_id|-subid            : The subscription ID of the SP.
  --tenant_id|-tid                    : The tenant id of the SP.
  --resource_group|-rg                : The resource group name.
  --kcluster_name|-kcn                : The Kinetica cluster resource name for identification in Kubernetes
  --license_key|-lk                   : The Kinetica Service license key
  --ranks|-rnk                        : The number of ranks to create
  --rank_storage|-rnkst               : The amount of disk space needed per rank
  --deployment_type|-dt               : Whether the AKS cluster uses CPU's or GPU's
EOF
}

function throw_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "Parameter '$name' cannot be empty." 1>&2
    print_usage
    exit -1
  fi
}

function init() {
  echo "\n---------- Init ----------\n"
  apt-get update --yes
  apt-get install wget --yes
}

function azureCliInstall() {
  echo "\n---------- Installing Az Cli ----------\n"
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  
  if [ "$auth_type" = "sp" ]; then
    az login --service-principal -u "$client_id" -p "$client_secret" -t "$tenant_id"
  else  
    az login --identity
  fi
  
  az account set --subscription "${subscription_id}"
  az aks get-credentials --resource-group "${resource_group}" --name "${aks_name}"
}

function installKubectl() {
  if !(command -v kubectl >/dev/null); then
    echo "\n---------- Installing Kubectl ----------\n"
    kubectl_file="/usr/local/bin/kubectl"
    curl -L -s -o $kubectl_file https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
    chmod +x $kubectl_file
  fi
  checkKubeReady
}

function checkKubeReady() {
  for i in `seq 0 10`; do
    if kubectl get nodes; then
      echo "k8 ready"
      break
    else
      echo "k8 not ready yet... retrying"
      sleep 10s
    fi
  done
}

function preflightOperator() {
  pushd /usr/local/bin/
  if !(command -v docker >/dev/null); then
    echo "\n---------- Installing Docker ----------\n"
    sudo apt-get install docker.io --yes
  fi
  if !(command -v porter >/dev/null); then
    echo "\n---------- Installing Porter ----------\n"
    pushd /usr/local/bin/
    curl https://cdn.porter.sh/latest/install-linux.sh | bash
    ln -s ~/.porter/porter /usr/local/bin/porter 
    ln -s ~/.porter/porter-runtime /usr/local/bin/porter-runtime
    echo "\n---------- Installing Porter Mixins ----------\n"
    porter mixin install helm3 --version v0.1.5 --feed-url  https://mchorfa.github.com/porter-helm3/atom.xml
    porter mixin install kustomize --url https://github.com/donmstewart/porter-kustomize/releases/download --version 0.2-beta-4
  fi
  if !(command -v kustomize >/dev/null); then
    echo "\n---------- Installing Kustomize ----------\n"
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
  fi
  popd
}

function gpuSetup() {
  echo "\n---------- Setting Up Nvidia Device Plugin DaemonSet ----------\n"
  if !(kubectl get ns gpu-resources &>/dev/null); then
    kubectl create ns gpu-resources
  fi
  cat <<EOF | kubectl apply  -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: gpu-resources
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      # Mark this pod as a critical add-on; when enabled, the critical add-on scheduler
      # reserves resources for critical add-on pods so that they can be rescheduled after
      # a failure.  This annotation works in tandem with the toleration below.
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ""
      labels:
        name: nvidia-device-plugin-ds
    spec:
      tolerations:
      # Allow this pod to be rescheduled while the node is in "critical add-ons only" mode.
      # This, along with the annotation above marks this pod as a critical add-on.
      - key: CriticalAddonsOnly
        operator: Exists
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - image: nvidia/k8s-device-plugin:1.11
        name: nvidia-device-plugin-ctr
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
          - name: device-plugin
            mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
EOF
}

function loadOperator() {
  echo "\n---------- Generating Porter Credentials ----------\n"
  #porter credentials generate --tag kinetica/kinetica-k8s-operator:v0.1
  TIMESTAMP=$(date -u +%Y-%m-%dT%T.%NZ)
  mkdir -p /root/.porter/credentials/
  touch /root/.porter/credentials/kinetica-k8s-operator.json
  cat <<EOF | tee /root/.porter/credentials/kinetica-k8s-operator.json
{
  "name": "kinetica-k8s-operator",
  "created": "$TIMESTAMP",
  "modified": "$TIMESTAMP",
  "credentials": [
    {
      "name": "kubeconfig",
      "source": {
        "path": "/root/.kube/config"
      }
    }
  ]
}
EOF

  echo "\n---------- Installing Kinetica Operator ----------\n"
  porter install kinetica-k8s-operator -c kinetica-k8s-operator -t kinetica/kinetica-k8s-operator:v0.3 --param environment=aks
}

function deployKineticaCluster() {
  echo "\n---------- Creating Kinetica Cluster ----------\n"
  # change to manged premium after the fact
  cat <<EOF | kubectl apply -f -
apiVersion: app.kinetica.com/v1
kind: KineticaCluster
metadata:
  name: "$kcluster_name"
  namespace: gpudb
spec:
  clusterDaemon:
    bindAddress: "serf://0.0.0.0:7946"
    rpcAddress: "rpc://127.0.0.1:7373"
  hostManagerMonitor:
    maxRankFailureCount: 12
  ingressController: kong
  gpudbCluster:
    license: "$license_key"
    image: kinetica/kinetica-k8s-intel:v0.2
    clusterName: "$kcluster_name"
    replicas: $ranks
    rankStorageSize: "$rank_storage"
    persistTier:
      volumeClaim:
        spec:
          storageClassName: "default"
    diskCacheTier:
      volumeClaim:
        spec:
          storageClassName: "default"
    hostManagerPort:
      name: "hostmanager"
      protocol: TCP
      containerPort: 9300
    resources:
      limits:
        cpu: "1.5"
        memory: "4Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
  gadmin:
    isEnabled: true
    containerPort:
      name: "gadmin"
      protocol: TCP
      containerPort: 8080
  reveal:
    isEnabled: true
    containerPort:
      name: "reveal"
      protocol: TCP
      containerPort: 8088
EOF

}

#---------------------------------------------------------------------------------

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --aks_name|-an)
      aks_name="$1"
      shift
      ;;
    --auth_type|-at)
      auth_type="$1"
      shift
      ;;
    --client_id|-clid)
      client_id="$1"
      shift
      ;;
    --client_secret|-clis)
      client_secret="$1"
      shift
      ;;
    --subscription_id|-subid)
      subscription_id="$1"
      shift
      ;;
    --tenant_id|-tid)
      tenant_id="$1"
      shift
      ;;
    --resource_group|-rg)
      resource_group="$1"
      shift
      ;;
# Kinetica Cluster details
    --kcluster_name|-kcn)
      kcluster_name="$1"
      shift
      ;;
    --license_key|-lk)
      license_key="$1"
      shift
      ;;
    --ranks|-rnk)
      ranks="$1"
      shift
      ;;
    --rank_storage|-rkst)
      rank_storage="$1"
      shift
      ;;
    --deployment_type|-dt)
      deployment_type="$1"
      shift
      ;;
    --help|-help|-h)
      print_usage
      exit 13
      ;;
    *)
      echo "ERROR: Unknown argument '$key' to script '$0'" 1>&2
      exit -1
  esac
done

#---------------------------------------------------------------------------------

throw_if_empty --aks_name "$aks_name"
throw_if_empty --auth_type "$auth_type"
throw_if_empty --subscription_id "$subscription_id"
throw_if_empty --resource_group "$resource_group"
throw_if_empty --kcluster_name "$kcluster_name"
throw_if_empty --ranks "$ranks"
throw_if_empty --rank_storage "$rank_storage"
throw_if_empty --deployment_type "$deployment_type"

if [ "$auth_type" = "sp" ]; then
  throw_if_empty --client_id "$client_id"
  throw_if_empty --client_secret "$client_secret"
  throw_if_empty --tenant_id "$tenant_id"
fi

azureCliInstall

installKubectl

preflightOperator

if [ "$deployment_type" = "gpu" ]; then
  gpuSetup
fi

loadOperator

deployKineticaCluster

