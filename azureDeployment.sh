#!/bin/bash -l

set -o errexit
readonly LOG_FILE="/var/log/kineticak8_az_deployment.log"
sudo touch $LOG_FILE
#exec 1> >(tee -a $LOG_FILE)
exec 1> $LOG_FILE
exec 2>&1
exec 19>&1
export BASH_XTRACEFD=19
set -x

####__________________________________
export KUBECONFIG=/root/.kube/config
veleroVersion=v1.4.2

workbench_image_tag="v7.1.3.13"
db_image_tag="v7.1.2.1-v0.2.17"


echo $@
function print_usage() {
  cat <<EOF
Auto Loads AKS cluster with kinetica operator (login and cli are disabled)
Command
  $0
Arguments
  --aks_name                          : The name of the AKS cluster to connect to
  --subscription_id                   : The subscription ID of the SP.
  --resource_group                    : The resource group name.
  --kcluster_name                     : The Kinetica cluster resource name for identification in Kubernetes
  --license_key                       : The Kinetica Service license key
  --ranks                             : The number of ranks to create
  --deployment_type                   : Whether the AKS cluster uses CPU's or GPU's
  --aks_infra_rg                      : The custom RG name for the AKS backend
  --identity_name                     : The Azure Identity Name of the managed identity that will be added to the scalesets
  --id_client_id                      : The Azure Client ID of the managed identity that will be added to the pod identity
  --operator_version                  : The version of the Kinetica-K8s-Operator image to use
  --storage_acc_name                  : The storage account name that will be used by Kinetica
  --blob_container_name               : The blob container where the backups will be stored
  --kinetica_user                     : The Kinetica Administrator User to manage Workbench
  --kinetica_pass                     : The Kinetica Administrator Password to manage Workbench
  --ssl_type                          : The type of SSL security to be implemented 'auto' will use let's encrypt, 'provided' will use the cert and key from ssl_cert and ssl_key parameters
  --ssl_cert                          : The SSL Certificate to be used to secure the ingress controller
  --ssl_key                           : The corresponding SSL Key to be used to secure the ingress controller
  --aks_vnet_name                     : The AKS Virtual Network Name to create the VPC peering
  --fw_vnet_name                      : The Firewall Virtual Network Name to create the VPC peering
  --environment                       : Whether to deploy let's encrypt staging or prod versions when deploying
  --workbench_operator_version        : The version of the Workbench Operator to deploy.
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
  
  az login --identity
  
  az account set --subscription "${subscription_id}"
  az aks get-credentials --resource-group "${resource_group}" --name "${aks_name}"

  az config set extension.use_dynamic_install=yes_without_prompt

  ## Add managed identity to scalesets

  for ssname in $(az vmss list --resource-group "$aks_infra_rg" --query "[].name" --output tsv); do
    az vmss identity assign -g "$aks_infra_rg" -n "$ssname" --identities "$identity_resource_id"
  done

  
  echo "\n---------- Gather Azure Info ----------\n"
  fqdn=$(az network public-ip show -n "${aks_name}-fw-ip" -g "${resource_group}" --query "dnsSettings.fqdn" -o tsv)
  public_IP=$(az network public-ip show -n "${aks_name}-fw-ip" -g "${resource_group}" --query "ipAddress" -o tsv)
  aks_vnet_id=$(az network vnet show -n "${aks_vnet_name}" -g ${resource_group} --query "id" -o tsv)
  fw_vnet_id=$(az network vnet show -n "${fw_vnet_name}" -g ${resource_group} --query "id" -o tsv)
  storage_acc_key=$(az storage account keys list -g ${resource_group} -n ${storage_acc_name} --query [0].value -o tsv)
  sas_exp_date=$(date -u -d "7 days" '+%Y-%m-%dT%H:%MZ')
  storage_acc_sas_tkn=$(az storage container generate-sas --account-name ${storage_acc_name} --account-key ${storage_acc_key}  -n ${blob_container_name} --permissions acdlrw --auth-mode key --expiry ${sas_exp_date} -o tsv)
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

function installPodIdentity() {
  echo "\n---------- ENV ----------\n"
  cat <<EOF > /opt/info.sh
#!/bin/bash
export AZURE_SUBSCRIPTION_ID=$subscription_id
export AZURE_RESOURCE_GROUP=$aks_infra_rg
export AZURE_CLOUD_ENV=AzurePublicCloud
export AZURE_BACKUP_RESOURCE_GROUP=$resource_group
export AZURE_STORAGE_ACCOUNT_ID=$storage_acc_name
export AZURE_BLOB_CONTAINER=$blob_container_name
export AZURE_IDENTITY_NAME=$identity_name
export AZURE_IDENTITY_RESOURCE_ID=$identity_resource_id
export AZURE_IDENTITY_CLIENT_ID=$id_client_id
EOF
  chmod +x /opt/info.sh
  source /opt/info.sh
  
  echo "\n---------- Installing Pod Identity Deployment ----------\n"
  kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment.yaml
  echo "\n---------- Creating Identity Object ----------\n"
  cat <<EOF | kubectl create -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: $AZURE_IDENTITY_NAME
spec:
  type: 0
  resourceID: $AZURE_IDENTITY_RESOURCE_ID
  clientID: $AZURE_IDENTITY_CLIENT_ID
EOF
  
  echo "\n---------- Creating Identity Binding ----------\n"
  cat <<EOF | kubectl create -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: $AZURE_IDENTITY_NAME-binding
spec:
  azureIdentity: $AZURE_IDENTITY_NAME
  selector: $AZURE_IDENTITY_NAME
EOF

}

function installVeleroCli() {
  if !(command -v velero >/dev/null); then

    echo "\n---------- Installing Velero Cli ----------\n"
    velero_install_dir="/opt/velero"
    mkdir -p "$velero_install_dir"
    velero_file="/usr/local/bin/velero"
    curl -L -s -o $velero_install_dir/velero.tar.gz https://github.com/vmware-tanzu/velero/releases/download/$veleroVersion/velero-$veleroVersion-linux-amd64.tar.gz
    tar -C $velero_install_dir -zxvf $velero_install_dir/velero.tar.gz
    chmod +x $velero_install_dir/velero-$veleroVersion-linux-amd64/velero
    ln -s $velero_install_dir/velero-$veleroVersion-linux-amd64/velero $velero_file
  
  fi
  echo "\n---------- Config Velero Cli ----------\n"
  cat <<EOF > ./credentials-velero
AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
AZURE_CLOUD_NAME=${AZURE_CLOUD_ENV}
EOF

  velero install \
  --provider azure \
  --plugins velero/velero-plugin-for-microsoft-azure:main \
  --bucket $AZURE_BLOB_CONTAINER \
  --secret-file ./credentials-velero \
  --backup-location-config resourceGroup=$AZURE_BACKUP_RESOURCE_GROUP,storageAccount=$AZURE_STORAGE_ACCOUNT_ID,subscriptionId=$AZURE_SUBSCRIPTION_ID \
  --snapshot-location-config apiTimeout=10m,resourceGroup=$AZURE_BACKUP_RESOURCE_GROUP,subscriptionId=$AZURE_SUBSCRIPTION_ID \
  --velero-pod-cpu-request 1 \
  --velero-pod-mem-request 5Gi \
  --velero-pod-cpu-limit 2 \
  --velero-pod-mem-limit 7Gi

  kubectl patch deployment velero -n velero --patch \
  '{"spec":{"template":{"metadata":{"labels":{"aadpodidbinding":"'$AZURE_IDENTITY_NAME'"}}}}}'
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
    curl https://cdn.porter.sh/v0.33.0/install-linux.sh | bash
    ln -s ~/.porter/porter /usr/local/bin/porter 
    ln -s ~/.porter/porter-runtime /usr/local/bin/porter-runtime
  fi
  popd

  loadSSLCerts

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

  echo "\n---------- Set LDAP AUTH ----------\n"
  cat <<EOF | tee /values.yaml
env:
  LDAP_ORGANISATION: "Kinetica DB Inc."
  LDAP_DOMAIN: "kinetica.com"

customLdifFiles:
  01-default-users.ldif: |-
    dn: ou=global_admins,dc=kinetica,dc=com
    objectClass: organizationalUnit
    ou: global_admins
    
    dn: uid=${kinetica_user},ou=global_admins,dc=kinetica,dc=com
    objectclass: person
    objectclass: inetOrgPerson
    uid: ${kinetica_user}
    cn: ${kinetica_user}
    sn: Admin
    userPassword: ${kinetica_pass}

persistence:
  enabled: true
  accessMode: ReadWriteOnce
  stroageClassName: Default
  size: 8Gi

affinity: 
  nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: app.kinetica.com/pool
                operator: In
                values:
                  - infra
  podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
         matchExpressions:
         - key: app
           operator: In
           values:
           - nginx-ingress
        topologyKey: kubernetes.io/hostname

EOF
  echo "\n---------- Installing Kinetica Operator ----------\n"
  porter storage migrate
  porter install -c kinetica-k8s-operator --reference kinetica/kinetica-k8s-operator:"$operator_version" --param environment=aks --param kineticaLDAPAdmin=/values.yaml --param storageclass="managed-premium"
  porter install -c kinetica-k8s-operator --reference kinetica/workbench-operator:"$workbench_operator_version"
  kubectl -n kineticaoperator-system create secret generic managed-id --from-literal=resourceid="$identity_resource_id"
  kubectl -n workbench-operator-system create secret generic managed-id --from-literal=resourceid="$identity_resource_id"
}

function deployKineticaCluster() {
  echo "\n---------- Creating Kinetica Cluster ----------\n"
  # change to manged premium after the fact
  cat <<EOF | tee /opt/kinetica_cluster.yaml
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
      failureThreshold: 30
  ingressController: nginx
  gpudbCluster:
    fqdn: "$fqdn"
    letsEncrypt: 
      enabled: true
      environment: "$ssl_env"
    podManagementPolicy: Parallel
    license: "$license_key"
    image: kinetica/kinetica-k8s-intel:${db_image_tag}
    clusterName: "$kcluster_name"
    config:
        enableTextSearch: true
        tieredStorage:
          persistTier:
            default:  
              volumeClaim:
                spec:
                  storageClassName: "managed-premium"
          diskCacheTier:
            default:
              volumeClaim:
                spec:
                  storageClassName: "managed-premium"
          coldStorageTier:
            coldStorageType: azure_blob
            coldStorageAzure:
              basePath: "gpudb/cold_storage/"
              containerName: "$blob_container_name"
              sasToken: "$storage_acc_sas_tkn"
              storageAccountKey: "$storage_acc_key"
              storageAccountName: "$storage_acc_name"
    # For operators higher than 2.4
    hasPools: true
    ranksPerNode: 1
    replicas: $ranks
    hostManagerPort:
      name: "hostmanager"
      protocol: TCP
      containerPort: 9300
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
  kubectl -n gpudb apply --wait -f /opt/kinetica_cluster.yaml
  kubectl -n gpudb create secret generic managed-id --from-literal=resourceid="$identity_resource_id"
}

function deployWorkbench() {
  echo "\n---------- Creating Workbench ----------\n"
  # change to manged premium after the fact
  cat <<EOF | tee /opt/workbench.yaml
apiVersion: workbench.com.kinetica/v1
kind: Workbench
metadata:
  name: "workbench"
  namespace: "kinetica-workbench"
spec:
  fqdn: "$fqdn"
  letsEncrypt:
    enabled: true
    environment: "$ssl_env"
  image: kinetica/workbench:$workbench_image_tag
EOF
  kubectl create ns kinetica-workbench
  kubectl -n kinetica-workbench create secret generic managed-id --from-literal=resourceid="$identity_resource_id"
  kubectl -n kinetica-workbench apply --wait -f /opt/workbench.yaml
}

function loadSSLCerts() {
  kubectl create ns nginx
  if [ "$ssl_type" = "provided" ]; then
    mkdir -p /opt/certs
    curl "$ssl_cert" --output /opt/certs/cert.crt
    curl "$ssl_key" --output /opt/certs/key.key
    kubectl -n nginx create secret generic tls-secret --from-file=tls.crt=/opt/certs/cert.crt --from-file=tls.key=/opt/certs/key.key
  else
    kubectl -n nginx create secret generic tls-secret
  fi
}

function azureNetworking(){
  echo "\n---------- Setup Firewall ----------\n"
  echo "\n---------- Firewall Rules ----------\n"
  echo "\n---------- 443 pass through ----------\n"
  az network firewall nat-rule create \
    --resource-group "${resource_group}" \
    --firewall-name "${aks_name}-fw" \
    --collection-name "aks-ingress-dnat-rules-443" \
    --priority "100" \
    --action "dnat" \
    --name "dnat-to-lb-443" \
    --protocol "TCP" \
    --source-addresses "*" \
    --destination-addresses "${public_IP}" \
    --destination-port "443" \
    --translated-address "${clusterIP}" \
    --translated-port "443"
    
  echo "\n---------- 80 pass through ----------\n"

  az network firewall nat-rule create \
    --resource-group "${resource_group}" \
    --firewall-name "${aks_name}-fw" \
    --collection-name "aks-ingress-dnat-rules-80" \
    --priority "200" \
    --action "dnat" \
    --name "dnat-to-lb-80" \
    --protocol "TCP" \
    --source-addresses "*" \
    --destination-addresses "${public_IP}" \
    --destination-port "80" \
    --translated-address "${clusterIP}" \
    --translated-port "80"
}

function updateScaleDownPolicy() {
  # Set gpudb scaleset to min 0 for pause-resume
  sc_name=$(az aks nodepool list -g ${resource_group} --cluster-name ${aks_name} --query "[?contains(name, 'gpudb')].name" -o tsv)
  az aks nodepool update -n ${sc_name} -g "${resource_group}" --cluster-name ${aks_name} -u --min-count 0 --max-count ${ranks}
}

function checkForClusterIP() {
  # Wait for service to be up:
  count=0
  attempts=360
  while [[ "$(kubectl -n nginx get svc ingress-nginx-controller -o jsonpath='{$.status.loadBalancer.ingress[*].ip}')" == "" ]]; do
    echo "waiting for ip to be ready"
    count=$((count+1))
    if [ "$count" -eq "$attempts" ]; then
      echo "ERROR: Timeout reached while waiting for IP address to be provisioned, please review deployment for any possible issues, or contact technical support for assistance"
      exit 1
    fi 

    if kubectl -n nginx describe svc ingress-nginx-controller | grep SyncLoadBalancerFailed; then
        kubectl -n nginx get svc -o yaml ingress-nginx-controller > /opt/ingress_controller.yaml
        kubectl delete -f /opt/ingress_controller.yaml
        kubectl apply -f /opt/ingress_controller.yaml
    fi

    sleep 10
  done
  # Get external IP Address:
  clusterIP="$(kubectl -n nginx get svc ingress-nginx-controller -o jsonpath='{$.status.loadBalancer.ingress[*].ip}')"
  echo "https://$fqdn:443/gadmin" > /opt/ipaddr
}

function checkForKineticaRanksReadiness() {
  # Wait for pods to be in ready state:
  count=0
  attempts=120
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

function createGlobalAdmins() {
  curl -X POST -H 'content-type: application/json' -d '{"name":"local_admins", "options": {}}' https://$fqdn/$kcluster_name/gpudb-0/create/role --user "$kinetica_user:$kinetica_pass"
  curl -X POST -H 'content-type: application/json' -d '{"name":"local_admins", "permission": "system_admin", "options": {}}' https://$fqdn/$kcluster_name/gpudb-0/grant/permission/system --user "$kinetica_user:$kinetica_pass"
}

#---------------------------------------------------------------------------------

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --aks_name)
      aks_name="$1"
      shift
      ;;
    --subscription_id)
      subscription_id="$1"
      shift
      ;;
    --resource_group)
      resource_group="$1"
      shift
      ;;
# Kinetica Cluster details
    --kcluster_name)
      kcluster_name="$1"
      shift
      ;;
    --license_key)
      license_key="$1"
      shift
      ;;
    --ranks)
      ranks="$1"
      shift
      ;;
    --deployment_type)
      deployment_type="$1"
      shift
      ;;
    --aks_infra_rg)
      aks_infra_rg="$1"
      shift
      ;;
    --operator_version)
      operator_version="$1"
      shift
      ;;
    --identity_name)
      identity_name="$1"
      shift
      ;;
    --id_client_id)
      id_client_id="$1"
      shift
      ;;
    --storage_acc_name)
      storage_acc_name="$1"
      shift
      ;;
    --blob_container_name)
      blob_container_name="$1"
      shift
      ;;
    --ssl_type)
      ssl_type="$1"
      shift
      ;;
    --ssl_cert)
      ssl_cert="$1"
      shift
      ;;
    --ssl_key)
      ssl_key="$1"
      shift
      ;;
    --aks_vnet_name)
      aks_vnet_name="$1"
      shift
      ;;
    --fw_vnet_name)
      fw_vnet_name="$1"
      shift
      ;;
    --kinetica_user)
      kinetica_user="$1"
      shift
      ;;
    --kinetica_pass)
      kinetica_pass="$1"
      shift
      ;;
    --environment)
      environment="$1"
      shift
      ;;
    --workbench_operator_version)
      workbench_operator_version="$1"
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
throw_if_empty --subscription_id "$subscription_id"
throw_if_empty --resource_group "$resource_group"
throw_if_empty --kcluster_name "$kcluster_name"
throw_if_empty --ranks "$ranks"
throw_if_empty --deployment_type "$deployment_type"
throw_if_empty --operator_version "$operator_version"
throw_if_empty --workbench_operator_version "$workbench_operator_version"
throw_if_empty --aks_infra_rg "$aks_infra_rg"
throw_if_empty --identity_name "$identity_name"
throw_if_empty --id_client_id "$id_client_id"
throw_if_empty --storage_acc_name "$storage_acc_name"
throw_if_empty --blob_container_name "$blob_container_name"
throw_if_empty --ssl_type "$ssl_type"
throw_if_empty --aks_vnet_name "$aks_vnet_name"
throw_if_empty --fw_vnet_name "$fw_vnet_name"
if [ "$ssl_type" = "provided" ]; then
  throw_if_empty --ssl_cert "$ssl_cert"
  throw_if_empty --ssl_key "$ssl_key"
fi

if [ "$environment" = "dev" ]; then
  ssl_env="staging"
else
  ssl_env="production"
fi

identity_resource_id="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identity_name"

if [ -z "$HOME" ]; then
    # Needed for porter download/install
    export HOME=/root
fi

azureCliInstall

installKubectl

if [ "$deployment_type" = "gpu" ]; then
  gpuSetup
fi

preflightOperator

loadOperator

installPodIdentity 

installVeleroCli

echo "\n---------- Waiiting for Ingress to be available --\n"
checkForClusterIP

deployKineticaCluster
deployWorkbench

azureNetworking

updateScaleDownPolicy

checkForKineticaRanksReadiness

createGlobalAdmins

#checkForGadmin
