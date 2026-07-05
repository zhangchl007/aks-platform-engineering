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
  [string]$Provider = "aks",
  [int]$TokenDurationHours = 8760
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

function Test-ClusterToken {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Server,
    [Parameter(Mandatory = $true)][string]$CaData,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $testKubeconfig = Join-Path $env:TEMP "$Name-token-validation-kubeconfig"
  $testCaFile = Join-Path $env:TEMP "$Name-token-validation-ca.crt"
  try {
    Remove-Item $testKubeconfig, $testCaFile -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllBytes($testCaFile, [Convert]::FromBase64String($CaData))
    kubectl config --kubeconfig $testKubeconfig set-cluster $Name --server=$Server --certificate-authority=$testCaFile | Out-Null
    kubectl config --kubeconfig $testKubeconfig set-credentials argocd-manager --token=$Token | Out-Null
    kubectl config --kubeconfig $testKubeconfig set-context $Name --cluster=$Name --user=argocd-manager | Out-Null
    kubectl --kubeconfig $testKubeconfig --context $Name auth can-i list namespaces | Out-Null
    return $LASTEXITCODE -eq 0
  } finally {
    Remove-Item $testKubeconfig, $testCaFile -Force -ErrorAction SilentlyContinue
  }
}

foreach ($tool in @("az", "kubectl")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Required tool '$tool' not found on PATH."
  }
}

Write-Step "Getting credentials for AKS workload cluster $ClusterName"
$workloadKubeconfig = Join-Path $env:TEMP "$ClusterName-admin-kubeconfig"
Remove-Item $workloadKubeconfig -Force -ErrorAction SilentlyContinue
az aks get-credentials `
  --resource-group $ResourceGroupName `
  --name $ClusterName `
  --admin `
  --file $workloadKubeconfig `
  --overwrite-existing | Out-Null

$workloadContext = "$ClusterName-admin"
kubectl --kubeconfig $workloadKubeconfig --context $workloadContext get nodes | Out-Null
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
"@ | kubectl --kubeconfig $workloadKubeconfig --context $workloadContext apply -f - | Out-Null

$tokenDuration = "${TokenDurationHours}h"
$token = kubectl --kubeconfig $workloadKubeconfig --context $workloadContext -n $saNamespace create token $saName --duration=$tokenDuration
$server = kubectl --kubeconfig $workloadKubeconfig --context $workloadContext config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}'
$caData = kubectl --kubeconfig $workloadKubeconfig --context $workloadContext config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'

Write-Step "Validating freshly minted ArgoCD manager token"
if (-not (Test-ClusterToken -Name $ClusterName -Server $server -CaData $caData -Token $token)) {
  throw "Fresh ArgoCD manager token cannot list namespaces on '$ClusterName'. Registration aborted."
}
Write-Ok "Fresh token can authenticate to $ClusterName"

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

Write-Step "Validating ArgoCD cluster Secret after write"
$storedSecretJson = kubectl --context $ControlPlaneContext -n $ArgoCDNamespace get secret $ClusterName -o json | ConvertFrom-Json
$storedServer = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($storedSecretJson.data.server))
$storedConfigJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($storedSecretJson.data.config))
$storedConfig = $storedConfigJson | ConvertFrom-Json
if (-not (Test-ClusterToken -Name $ClusterName -Server $storedServer -CaData $storedConfig.tlsClientConfig.caData -Token $storedConfig.bearerToken)) {
  throw "Stored ArgoCD cluster Secret for '$ClusterName' cannot authenticate. Registration aborted."
}
Write-Ok "Stored ArgoCD cluster Secret can authenticate to $ClusterName"

Write-Ok "Registered $ClusterName with control-plane ArgoCD"

Remove-Item $workloadKubeconfig -Force -ErrorAction SilentlyContinue
