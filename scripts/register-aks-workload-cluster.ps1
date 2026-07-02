<#
.SYNOPSIS
  Register an AKS workload cluster into the control-plane ArgoCD.

.DESCRIPTION
  The control-plane ArgoCD can provision workload clusters through CAPZ. This
  script is optional: use it when you also want the control-plane ArgoCD to target
  the new AKS workload cluster directly as a managed destination.

  It creates an argocd-manager service account in the workload cluster, mints a
  token, and applies an ArgoCD cluster Secret to the control-plane ArgoCD
  namespace.

  Note: registering the workload cluster centrally may cause GitOps Bridge
  ApplicationSets to target it, depending on labels/selectors in the repo.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ClusterName,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [string]$ControlPlaneContext = "gitops-aks",
  [string]$ArgoCDNamespace = "argocd",
  [string]$Environment = "workload",
  [string]$Provider = "aks"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

foreach ($tool in @("az", "kubectl")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Required tool '$tool' not found on PATH."
  }
}

Write-Step "Getting credentials for AKS workload cluster $ClusterName"
az aks get-credentials `
  --resource-group $ResourceGroupName `
  --name $ClusterName `
  --overwrite-existing | Out-Null

$workloadContext = $ClusterName
kubectl --context $workloadContext get nodes | Out-Null
Write-Ok "Connected to workload context $workloadContext"

Write-Step "Creating ArgoCD manager service account in workload cluster"
$saNamespace = "argocd-managed"
$saName = "argocd-manager"
@"
apiVersion: v1
kind: Namespace
metadata:
  name: $saNamespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $saName
  namespace: $saNamespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $saName
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: $saName
    namespace: $saNamespace
"@ | kubectl --context $workloadContext apply -f - | Out-Null

$token = kubectl --context $workloadContext -n $saNamespace create token $saName --duration=8760h
$server = kubectl --context $workloadContext config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}'
$caData = kubectl --context $workloadContext config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'

Write-Step "Reading GitOps Bridge annotations from control-plane cluster Secret"
$hubSecretJson = kubectl --context $ControlPlaneContext -n $ArgoCDNamespace get secret gitops-aks -o json | ConvertFrom-Json
$hubAnnotations = $hubSecretJson.metadata.annotations

$config = @{
  bearerToken     = $token
  tlsClientConfig = @{ insecure = $false; caData = $caData }
} | ConvertTo-Json -Compress

$secret = @{
  apiVersion = "v1"
  kind       = "Secret"
  metadata   = @{
    name      = $ClusterName
    namespace = $ArgoCDNamespace
    labels    = @{
      "argocd.argoproj.io/secret-type" = "cluster"
      "environment"                    = $Environment
      "provider"                       = $Provider
    }
    annotations = @{
      addons_repo_url      = $hubAnnotations.addons_repo_url
      addons_repo_basepath = $hubAnnotations.addons_repo_basepath
      addons_repo_path     = $hubAnnotations.addons_repo_path
      addons_repo_revision = $hubAnnotations.addons_repo_revision
      subscription_id      = $hubAnnotations.subscription_id
      tenant_id            = $hubAnnotations.tenant_id
      akspe_identity_id    = $hubAnnotations.akspe_identity_id
    }
  }
  type       = "Opaque"
  stringData = @{
    name   = $ClusterName
    server = $server
    config = $config
  }
}

$outDir = Join-Path $PSScriptRoot ".arc-out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir "cluster-secret-$ClusterName.json"
$secret | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding utf8

Write-Step "Applying ArgoCD cluster Secret to control-plane ArgoCD"
kubectl --context $ControlPlaneContext apply -f $outFile | Out-Null
kubectl --context $ControlPlaneContext -n $ArgoCDNamespace get secret $ClusterName `
  -o "jsonpath={.metadata.labels}{'\n'}"

Write-Ok "Registered $ClusterName with control-plane ArgoCD"
