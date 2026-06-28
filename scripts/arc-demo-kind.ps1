<#
.SYNOPSIS
  Stand up a local kind cluster as a sample "external" (non-AKS) cluster and walk
  up to the Azure Arc onboarding boundary.

.DESCRIPTION
  This demonstrates the Arc onboarding wiring end-to-end on your workstation:
    1. Ensures kind + kubectl + az (+ connectedk8s) are installed (via winget).
    2. Creates a kind cluster named 'arc-demo'.
    3. Prints the exact next steps to Arc-connect it and register it into ArgoCD.

  It deliberately STOPS before 'az login' / 'az connectedk8s connect' so it never
  touches your Azure subscription without consent. Run the printed commands to
  finish onboarding.

  Reachability note: a kind cluster is reachable from THIS workstation but not
  from the AKS-hosted control-plane ArgoCD. The demo proves the onboarding +
  registration wiring; full remote sync to a private cluster requires network
  reachability or the Arc cluster-connect tunnel (see docs).

.PARAMETER ClusterName
  kind cluster name (also the Arc connectedCluster name). Default: arc-demo.

.PARAMETER SkipInstall
  Skip the winget tool installation step.
#>
[CmdletBinding()]
param(
  [string]$ClusterName = 'arc-demo',
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }

if (-not $SkipInstall) {
  Write-Step 'Ensuring kind / kubectl / az are installed (winget)'
  $tools = @(
    @{ Cmd = 'kind';    Id = 'Kubernetes.kind' },
    @{ Cmd = 'kubectl'; Id = 'Kubernetes.kubectl' },
    @{ Cmd = 'az';      Id = 'Microsoft.AzureCLI' }
  )
  foreach ($t in $tools) {
    if (Get-Command $t.Cmd -ErrorAction SilentlyContinue) {
      Write-Ok "$($t.Cmd) present"
    } else {
      Write-Step "Installing $($t.Id)"
      winget install --id $t.Id --silent --accept-package-agreements --accept-source-agreements
    }
  }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is required for kind but was not found. Start Docker Desktop and retry."
}

# --- Create the kind cluster ---------------------------------------------------
Write-Step "Creating kind cluster '$ClusterName'"
$existing = kind get clusters 2>$null
if ($existing -contains $ClusterName) {
  Write-Ok "kind cluster '$ClusterName' already exists"
} else {
  kind create cluster --name $ClusterName --wait 60s
  Write-Ok "kind cluster '$ClusterName' created"
}

$kctx = "kind-$ClusterName"
kubectl --context $kctx get nodes
Write-Ok "Context: $kctx"

# --- Next steps ---------------------------------------------------------------
Write-Host ''
Write-Step 'Next steps to finish Arc onboarding (run manually):'
Write-Host @"
  # 1. Authenticate to Azure (this script intentionally does not):
  az login

  # 2. Apply Terraform so the Arc RBAC + outputs exist (declare your cluster in
  #    var.arc_external_clusters, e.g. arc_external_clusters = { "$ClusterName" = "" }):
  cd terraform; terraform apply

  # 3. Onboard this kind cluster to Arc and register it into the control-plane ArgoCD.
  #    (Provide -ControlPlaneContext only if your kubeconfig can reach the AKS hub.)
  ./scripts/arc-onboard.ps1 -ClusterName $ClusterName -KubeContext $kctx

  # 4. Tear down the demo when done:
  kind delete cluster --name $ClusterName
"@ -ForegroundColor Gray
