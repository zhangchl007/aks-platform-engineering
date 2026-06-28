<#
.SYNOPSIS
  Bootstrap a private Azure VM-hosted kind cluster, connect it to Azure Arc, and
  register it into the AKS-hosted ArgoCD.

.DESCRIPTION
  This fixes the laptop-kind reachability problem by creating/using a kind API
  endpoint on the Azure VM private IP, which AKS can reach over the existing VNet.

  Assumes Terraform has been applied with:
    enable_arc_kind_vm = true
    arc_external_clusters = { "arc-demo-vm" = "" }

  The VM is operated through Azure VM Run Command. No public Kubernetes API and
  no SSH endpoint are required.
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "aks-gitops",
  [string]$VmName = "arc-kind-vm",
  [string]$ClusterName = "arc-demo-vm",
  [string]$ControlPlaneContext = "gitops-aks",
  [string]$TerraformDir,
  [int]$ApiPort = 6443
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

if (-not $TerraformDir) {
  $TerraformDir = Join-Path (Split-Path -Parent $PSScriptRoot) "terraform"
}

foreach ($tool in @("az", "kubectl", "terraform")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Required tool '$tool' not found on PATH."
  }
}

Write-Step "Reading Terraform outputs"
Push-Location $TerraformDir
try {
  $arc = terraform output -json arc_onboarding | ConvertFrom-Json
  $vm = terraform output -json arc_kind_vm | ConvertFrom-Json
} finally {
  Pop-Location
}

if (-not $vm) {
  throw "Terraform output 'arc_kind_vm' is null. Apply with enable_arc_kind_vm=true first."
}

$privateIp = $vm.private_ip
$server = "https://$privateIp`:$ApiPort"
Write-Ok "VM private IP: $privateIp"
Write-Ok "kind API server: $server"

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="__CLUSTER_NAME__"
RESOURCE_GROUP="__RESOURCE_GROUP__"
LOCATION="__LOCATION__"
SUBSCRIPTION_ID="__SUBSCRIPTION_ID__"
PRIVATE_IP="__PRIVATE_IP__"
API_PORT="__API_PORT__"
KUBECONFIG_PATH="/root/.kube/config"

export DEBIAN_FRONTEND=noninteractive
mkdir -p /opt/arc-kind

echo "==> Installing base packages"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https docker.io
systemctl enable --now docker

if ! command -v az >/dev/null 2>&1; then
  echo "==> Installing Azure CLI"
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "==> Installing kubectl"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "==> Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "==> Installing kind"
  curl -fsSL -o /usr/local/bin/kind https://github.com/kubernetes-sigs/kind/releases/download/v0.24.0/kind-linux-amd64
  chmod +x /usr/local/bin/kind
fi

cat >/opt/arc-kind/kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "${PRIVATE_IP}"
  apiServerPort: ${API_PORT}
nodes:
  - role: control-plane
EOF

export KUBECONFIG="${KUBECONFIG_PATH}"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "==> Creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --name "${CLUSTER_NAME}" --config /opt/arc-kind/kind.yaml --wait 180s
else
  echo "==> kind cluster ${CLUSTER_NAME} already exists"
fi

docker update --restart=unless-stopped "${CLUSTER_NAME}-control-plane" >/dev/null || true
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl get nodes

echo "==> Logging in to Azure with VM managed identity"
az login --identity --allow-no-subscriptions >/dev/null
az account set --subscription "${SUBSCRIPTION_ID}"
az extension add --name connectedk8s --upgrade --only-show-errors >/dev/null

existing="$(az connectedk8s list --resource-group "${RESOURCE_GROUP}" --query "[?name=='${CLUSTER_NAME}'].id | [0]" -o tsv)"
if [ -n "${existing}" ]; then
  echo "==> connectedCluster ${CLUSTER_NAME} already exists"
else
  echo "==> Connecting ${CLUSTER_NAME} to Azure Arc"
  az connectedk8s connect \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --kube-context "kind-${CLUSTER_NAME}" \
    --only-show-errors
fi

echo "==> Enabling cluster-connect"
az connectedk8s enable-features \
  --name "${CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --kube-context "kind-${CLUSTER_NAME}" \
  --features cluster-connect \
  --only-show-errors >/dev/null

echo "==> Creating ArgoCD service account"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: argocd-managed
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd-managed
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: argocd-managed
EOF

TOKEN="$(kubectl -n argocd-managed create token argocd-manager --duration=8760h)"
CA_DATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
SERVER="https://${PRIVATE_IP}:${API_PORT}"

echo "__ARC_KIND_PAYLOAD_BEGIN__"
echo "name=${CLUSTER_NAME}"
echo "server=${SERVER}"
echo "caData=${CA_DATA}"
echo "token=${TOKEN}"
echo "__ARC_KIND_PAYLOAD_END__"
'@

$remoteScript = $remoteScript.
  Replace("__CLUSTER_NAME__", $ClusterName).
  Replace("__RESOURCE_GROUP__", $ResourceGroup).
  Replace("__LOCATION__", $arc.location).
  Replace("__SUBSCRIPTION_ID__", $arc.subscription_id).
  Replace("__PRIVATE_IP__", $privateIp).
  Replace("__API_PORT__", [string]$ApiPort)

$tmp = Join-Path $env:TEMP "arc-kind-vm-bootstrap.sh"
Set-Content -Path $tmp -Value $remoteScript -Encoding ascii

Write-Step "Running bootstrap and Arc connect on VM $VmName"
$run = az vm run-command invoke `
  --resource-group $ResourceGroup `
  --name $VmName `
  --command-id RunShellScript `
  --scripts "@$tmp" `
  -o json | ConvertFrom-Json

$message = $run.value[0].message
Write-Host $message

$payload = @{}
$capture = $false
foreach ($line in ($message -split "`r?`n")) {
  if ($line -eq "__ARC_KIND_PAYLOAD_BEGIN__") { $capture = $true; continue }
  if ($line -eq "__ARC_KIND_PAYLOAD_END__") { $capture = $false; continue }
  if ($capture -and $line.Contains("=")) {
    $idx = $line.IndexOf("=")
    $payload[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
  }
}

foreach ($required in @("name", "server", "caData", "token")) {
  if (-not $payload.ContainsKey($required) -or -not $payload[$required]) {
    throw "VM bootstrap did not return required payload field '$required'."
  }
}

Write-Step "Registering VM-hosted kind cluster into ArgoCD"
$config = @{
  bearerToken     = $payload["token"]
  tlsClientConfig = @{ insecure = $false; caData = $payload["caData"] }
} | ConvertTo-Json -Compress

$secret = @{
  apiVersion = "v1"
  kind       = "Secret"
  metadata   = @{
    name      = $payload["name"]
    namespace = $arc.argocd_namespace
    labels    = @{
      "argocd.argoproj.io/secret-type" = "cluster"
      "environment"                    = "arc"
      "enable_arc_onboarding"          = "true"
      "provider"                       = "arc"
    }
    annotations = @{
      addons_repo_url      = $arc.addons_repo_url
      addons_repo_basepath = $arc.addons_repo_basepath
      addons_repo_path     = $arc.addons_repo_path
      addons_repo_revision = $arc.addons_repo_revision
      subscription_id      = $arc.subscription_id
      tenant_id            = $arc.tenant_id
      akspe_identity_id    = $arc.akspe_client_id
      arc_resource_group   = $ResourceGroup
    }
  }
  type       = "Opaque"
  stringData = @{
    name   = $payload["name"]
    server = $payload["server"]
    config = $config
  }
}

$outDir = Join-Path $PSScriptRoot ".arc-out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir "cluster-secret-$($payload["name"]).json"
$secret | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding utf8
kubectl --context $ControlPlaneContext apply -f $outFile | Out-Null

Write-Ok "Registered $($payload["name"]) with server $($payload["server"])"
Write-Step "Testing AKS-to-kind API reachability"
kubectl --context $ControlPlaneContext -n $arc.argocd_namespace run arc-kind-vm-netcheck --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- sh -c "curl -k -sS --connect-timeout 5 -m 10 $($payload["server"])/version"
