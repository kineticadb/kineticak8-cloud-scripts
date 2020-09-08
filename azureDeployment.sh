#!/bin/bash

set -o errexit
readonly LOG_FILE="/var/log/kineticak8_az_deployment.log"
sudo touch $LOG_FILE
#exec 1> >(tee -a $LOG_FILE)
exec 1> $LOG_FILE
exec 2>&1
exec 19>&1
export BASH_XTRACEFD="19"
set -x


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
  --aks_infra_rg|-airg                : The custom RG name for the AKS backend
  --id_resource_id|-idrn              : The Azure Resource ID of the managed identity that will be added to the scalesets
  --operator_version|-ov              : The version of the Kinetica-K8s-Operator image to use
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

  ## Add managed identity to scalesets

  for ssname in $(az vmss list --resource-group "$aks_infra_rg" --query "[].name" --output tsv); do
    az vmss identity assign -g "$aks_infra_rg" -n "$ssname" --identities "$id_resource_id"
  done
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
    curl https://cdn.porter.sh/v0.27.2/install-linux.sh | bash
    ln -s ~/.porter/porter /usr/local/bin/porter 
    ln -s ~/.porter/porter-runtime /usr/local/bin/porter-runtime
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

function checkForExternalIP() {
  # Wait for service to be up:
  count=0
  attempts=60
  while [[ "$(kubectl -n nginx get svc ingress-nginx-controller -o jsonpath='{$.status.loadBalancer.ingress[*].ip}')" == "" ]]; do
    echo "waiting for ip to be ready"
    count=$((count+1))
    if [ "$count" -eq "$attempts" ]; then
      echo "ERROR: Timeout reached while waiting for IP address to be provisioned, please review deployment for any possible issues, or contact technical support for assistance"
      exit 1
    fi 
    sleep 10
  done
  # Get external IP Address:
  clusterIP="$(kubectl -n nginx get svc ingress-nginx-controller -o jsonpath='{$.status.loadBalancer.ingress[*].ip}')"
  echo "http://$clusterIP/gadmin" > /opt/ipaddr
}

function loadOperator() {
  echo "\n---------- Generating Porter Credentials ----------\n"
  TIMESTAMP=$(date -u +%Y-%m-%dT%T.%NZ)
  mkdir -p /root/.porter/credentials/
  touch /root/.porter/credentials/kinetica-k8s-operator.json
  cat <<EOF | tee /root/.porter/credentials/kinetica-k8s-operator.json
{
  "schemaVersion": "1.0.0-DRAFT+b6c701f",
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
  porter install kinetica-k8s-operator -c kinetica-k8s-operator --tag kinetica/kinetica-k8s-operator:"$operator_version" --param environment=aks
  echo "\n---------- Waiiting for Ingress to be available --\n"
  checkForExternalIP
}

function deployKineticaCluster() {
  echo "\n---------- Creating Kinetica Cluster ----------\n"
  # change to manged premium after the fact
  cat <<EOF | kubectl apply --wait -f -
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
    livenessProbe:
      failureThreshold: 10
  ingressController: nginx
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
        cpu: "5"
        memory: "100Gi"
      requests:
        cpu: "4.5"
        memory: "50Gi"
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

  setSecrets
}

function checkForKineticaRanksReadiness() {
  # Wait for pods to be in ready state:
  count=0
  attempts=20
  while [[ "$(kubectl -n gpudb get sts -o jsonpath='{.items[*].status.readyReplicas}')" != "$ranks" ]]; do
    echo "waiting for pods to be up" 
    count=$((count+1))
    if [ "$count" -eq "$attempts" ]; then
      echo "ERROR: Timeout reached while waiting for Kinetica pods to be up, please review status of deployment, or contact technical support for assistance"
      break
    fi
    sleep 10
  done
}

function checkForGadmin() {
  # Make sure gadmin is up
  count=0
  attempts=10
  while [[ "$(curl -s -o /dev/null -L -w ''%{http_code}'' "$clusterIP"/gadmin)" != '200' ]]; do
    echo "Waiting for gadmin to be up"
    count=$((count+1))
    if [ "$count" -eq "$attempts" ]; then
      echo "ERROR: Timeout reached while waiting for Gadmin to be up, please review status of deployment, or contact technical support for assistance"
      break
    fi
    sleep 10
  done
}

function setSecrets() {
  kubectl -n gpudb create secret generic managed-id --from-literal=resourceid="$id_resource_id"
  kubectl -n kineticaoperator-system create secret generic managed-id --from-literal=resourceid="$id_resource_id"
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
    --aks_infra_rg|-airg)
      aks_infra_rg="$1"
      shift
      ;;
    --operator_version|-ov)
      operator_version="$1"
      shift
      ;;
    --id_resource_id|-idrn)
      id_resource_id="$1"
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
throw_if_empty --operator_version "$operator_version"
throw_if_empty --aks_infra_rg "$aks_infra_rg"
throw_if_empty --id_resource_id "$id_resource_id"

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

checkForKineticaRanksReadiness

checkForGadmin
