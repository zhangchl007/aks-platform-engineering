<#
.SYNOPSIS
  Onboard an external (non-AKS) Kubernetes cluster to Azure Arc and register it
  into the control-plane ArgoCD as a GitOps-managed cluster.

.DESCRIPTION
  Idempotent. Steps:
    1. Preflight (az CLI, connectedk8s extension, kubectl, login, providers).
    2. az connectedk8s connect  (onboard the target cluster to Azure Arc).
    3. Enable the cluster-connect feature.
    4. Create a cluster-admin ServiceAccount in the target cluster and mint a token.
    5. Build an ArgoCD cluster Secret and apply it to the control-plane's argocd ns.
    6. Verify ArgoCD sees the cluster.

  Reads onboarding context from:  terraform output -json arc_onboarding
  (run from the terraform/ directory, or pass -TerraformDir).

  Boundary: Azure Arc is for NON-AKS / external clusters only. Do not run this
  against the AKS hub (it is governed by Fleet Manager).

.PARAMETER ClusterName
  Logical name for the cluster. Used as the Arc connectedCluster name and the
  ArgoCD cluster Secret name. Should match a key in var.arc_external_clusters.

.PARAMETER KubeContext
  kubeconfig context of the TARGET external cluster (the one being onboarded).

.PARAMETER ControlPlaneContext
  kubeconfig context of the CONTROL-PLANE AKS (where ArgoCD runs). The script
  applies the cluster Secret here. If omitted, you must apply the rendered
  Secret yourself (the script writes it to disk).

.PARAMETER Location
  Azure region for the Arc resource. Defaults to the Terraform output location.

.PARAMETER TerraformDir
  Directory containing the Terraform state/outputs. Default: ../terraform
  relative to this script.

.EXAMPLE
  ./arc-onboard.ps1 -ClusterName arc-demo -KubeContext kind-arc-demo `
      -ControlPlaneContext aks-gitops
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ClusterName,
  [Parameter(Mandatory = $true)][string]$KubeContext,
  [string]$ControlPlaneContext,
  [string]$Location,
  [string]$TerraformDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($m)  { Write-Host "    $m"   -ForegroundColor Yellow }

if (-not $TerraformDir) {
  $TerraformDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform'
}

# --- Preflight -----------------------------------------------------------------
Write-Step 'Preflight checks'
foreach ($tool in @('az', 'kubectl')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Required tool '$tool' not found on PATH."
  }
}
$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) { throw "Not logged in. Run 'az login' first." }
Write-Ok "Subscription: $($acct.name) ($($acct.id))"

if (-not (az extension show --name connectedk8s 2>$null)) {
  Write-Step 'Installing az connectedk8s extension'
  az extension add --name connectedk8s --only-show-errors | Out-Null
}

# --- Load Terraform onboarding context ----------------------------------------
Write-Step "Reading onboarding context from $TerraformDir"
Push-Location $TerraformDir
try {
  $ctx = terraform output -json arc_onboarding | ConvertFrom-Json
} finally {
  Pop-Location
}
if (-not $ctx) { throw "Could not read 'arc_onboarding' output. Did you 'terraform apply'?" }

$rg     = $ctx.resource_group
$loc    = if ($Location) { $Location } elseif ($ctx.external_clusters.$ClusterName) { $ctx.external_clusters.$ClusterName } else { $ctx.location }
$argons = $ctx.argocd_namespace
Write-Ok "Resource group: $rg | Location: $loc | ArgoCD ns: $argons"

# --- Register providers (best-effort; may already be handled by Terraform) ----
Write-Step 'Ensuring Arc resource providers are registered'
foreach ($p in @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation')) {
  $state = (az provider show --namespace $p --query registrationState -o tsv 2>$null)
  if ($state -ne 'Registered') {
    Write-Warn2 "$p is '$state' - registering (this can take minutes)"
    az provider register --namespace $p --only-show-errors | Out-Null
  } else { Write-Ok "$p registered" }
}

# --- Arc connect ---------------------------------------------------------------
Write-Step "Connecting '$ClusterName' to Azure Arc"
$existing = az connectedk8s show --name $ClusterName --resource-group $rg 2>$null | ConvertFrom-Json
if ($existing) {
  Write-Ok "connectedCluster '$ClusterName' already exists - skipping connect"
} else {
  az connectedk8s connect `
    --name $ClusterName `
    --resource-group $rg `
    --location $loc `
    --kube-context $KubeContext `
    --only-show-errors
  Write-Ok "Arc connect complete"
}

Write-Step 'Enabling cluster-connect feature'
az connectedk8s enable-features `
  --name $ClusterName `
  --resource-group $rg `
  --kube-context $KubeContext `
  --features cluster-connect `
  --only-show-errors | Out-Null
Write-Ok 'cluster-connect enabled'

# --- Create cluster-admin ServiceAccount + token in the target cluster --------
Write-Step 'Creating ArgoCD service account in target cluster'
$saNs   = 'argocd-managed'
$saName = 'argocd-manager'
$saManifest = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $saNs
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $saName
  namespace: $saNs
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
    namespace: $saNs
"@
$saManifest | kubectl --context $KubeContext apply -f - | Out-Null

$token = kubectl --context $KubeContext -n $saNs create token $saName --duration=8760h 2>$null
if (-not $token) {
  # Fallback for older clusters without the TokenRequest API.
  $tokSecret = @"
apiVersion: v1
kind: Secret
metadata:
  name: $saName-token
  namespace: $saNs
  annotations:
    kubernetes.io/service-account.name: $saName
type: kubernetes.io/service-account-token
"@
  $tokSecret | kubectl --context $KubeContext apply -f - | Out-Null
  Start-Sleep -Seconds 3
  $token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(
    (kubectl --context $KubeContext -n $saNs get secret "$saName-token" -o jsonpath='{.data.token}')))
}
Write-Ok 'Service account token minted'

$server = kubectl --context $KubeContext config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}'
$caB64  = kubectl --context $KubeContext config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
Write-Ok "Target API server: $server"

# --- Render the ArgoCD cluster Secret -----------------------------------------
Write-Step 'Rendering ArgoCD cluster Secret'
$config = @{
  bearerToken     = $token
  tlsClientConfig = @{ insecure = $false; caData = $caB64 }
} | ConvertTo-Json -Compress

$secret = @{
  apiVersion = 'v1'
  kind       = 'Secret'
  metadata   = @{
    name      = $ClusterName
    namespace = $argons
    labels    = @{
      'argocd.argoproj.io/secret-type' = 'cluster'
      'environment'                    = 'arc'
      'enable_arc_onboarding'          = 'true'
      'provider'                       = 'arc'
    }
    annotations = @{
      addons_repo_url      = $ctx.addons_repo_url
      addons_repo_basepath = $ctx.addons_repo_basepath
      addons_repo_path     = $ctx.addons_repo_path
      addons_repo_revision = $ctx.addons_repo_revision
      subscription_id      = $ctx.subscription_id
      tenant_id            = $ctx.tenant_id
      akspe_identity_id    = $ctx.akspe_client_id
      arc_resource_group   = $rg
    }
  }
  type       = 'Opaque'
  stringData = @{ name = $ClusterName; server = $server; config = $config }
}

$outDir  = Join-Path $PSScriptRoot '.arc-out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir "cluster-secret-$ClusterName.yaml"
# Emit JSON (valid YAML) so kubectl can consume it directly.
$secret | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding utf8
Write-Ok "Wrote $outFile (contains a token - do NOT commit)"

# --- Apply to the control plane ------------------------------------------------
if ($ControlPlaneContext) {
  Write-Step "Registering cluster into ArgoCD (context: $ControlPlaneContext)"
  kubectl --context $ControlPlaneContext apply -f $outFile | Out-Null
  Write-Ok "ArgoCD cluster Secret applied to '$argons'"
  Write-Step 'Verifying registration'
  kubectl --context $ControlPlaneContext -n $argons get secret $ClusterName `
    -o "jsonpath={.metadata.labels}{'\n'}"
  Write-Ok "Done. The addons-arc-onboarding ApplicationSet will deploy the baseline."
} else {
  Write-Warn2 "No -ControlPlaneContext given. Apply the rendered Secret yourself:"
  Write-Warn2 "  kubectl --context <control-plane> apply -f $outFile"
}
