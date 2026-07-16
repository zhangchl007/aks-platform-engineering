<#
.SYNOPSIS
Creates the private Backstage multi-cluster Kubernetes connection Secret.

.DESCRIPTION
Creates short-lived service-account tokens from the GitOps-managed
backstage-kubernetes-reader identity and stores the resulting Backstage
configuration only in the backstage namespace. No token is written to Git,
Terraform input, or catalog metadata.

Run this after the platform-target-baseline ApplicationSet has synchronized the
reader identity to every target. Pass only Kubernetes contexts that are already
admin-capable for the target clusters.
#>
[CmdletBinding()]
param(
  [string]$ControlPlaneContext = "gitops-aks-admin",
  [string]$BackstageNamespace = "backstage",
  [string]$ConfigSecretName = "backstage-kubernetes-clusters",
  [string]$ReaderNamespace = "platform-access-system",
  [string]$ReaderServiceAccount = "backstage-kubernetes-reader",
  [hashtable]$TargetContexts = @{
    "gitops-aks"    = "gitops-aks-admin"
    "arc-demo-vm"   = "arc-demo-vm"
    "arc-demo-vm-2" = "arc-demo-vm-2"
  },
  [string[]]$AksClusterNames = @("gitops-aks"),
  [string]$AksDeployerGroupObjectId,
  [int]$TokenDurationHours = 24
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Kubectl {
  param(
    [string[]]$Arguments,
    [string]$ErrorMessage
  )

  $result = & kubectl @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw $ErrorMessage
  }

  return $result
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  throw "Required tool 'kubectl' was not found on PATH."
}

if ($TargetContexts.Count -eq 0) {
  throw "TargetContexts must include at least one Backstage cluster name and Kubernetes context."
}

$temporaryConfig = Join-Path $env:TEMP "$ConfigSecretName-kubernetes-clusters.yaml"
Remove-Item $temporaryConfig -Force -ErrorAction SilentlyContinue

try {
  $configLines = @(
    "kubernetes:",
    "  serviceLocatorMethod:",
    "    type: multiTenant",
    "  clusterLocatorMethods:",
    "    - type: config",
    "      clusters:"
  )

  foreach ($clusterName in $TargetContexts.Keys | Sort-Object) {
    $targetContext = [string]$TargetContexts[$clusterName]
    if ([string]::IsNullOrWhiteSpace($targetContext)) {
      throw "TargetContexts entry '$clusterName' has no Kubernetes context."
    }

    Invoke-Kubectl -Arguments @("--context", $targetContext, "get", "namespace", $ReaderNamespace) `
      -ErrorMessage "Context '$targetContext' cannot read namespace '$ReaderNamespace'. Synchronize platform-target-baseline before continuing." | Out-Null

    $token = Invoke-Kubectl -Arguments @(
      "--context", $targetContext,
      "-n", $ReaderNamespace,
      "create", "token", $ReaderServiceAccount,
      "--duration=$($TokenDurationHours)h"
    ) -ErrorMessage "Could not mint a Backstage reader token for '$clusterName'."

    $token = ($token | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
      throw "The Backstage reader token for '$clusterName' was empty."
    }

    Invoke-Kubectl -Arguments @(
      "--context", $targetContext,
      "--token", $token,
      "auth", "can-i", "list", "deployments.apps", "--all-namespaces"
    ) -ErrorMessage "Could not validate the Backstage reader token for '$clusterName'." | Out-Null

    $clusterConfig = Invoke-Kubectl -Arguments @(
      "--context", $targetContext,
      "config", "view", "--minify", "--raw", "-o", "json"
    ) -ErrorMessage "Could not read Kubernetes connection details for '$clusterName'." | ConvertFrom-Json

    $connection = $clusterConfig.clusters[0].cluster
    if ([string]::IsNullOrWhiteSpace($connection.server) -or [string]::IsNullOrWhiteSpace($connection."certificate-authority-data")) {
      throw "Context '$targetContext' does not provide a server URL and CA data for '$clusterName'."
    }

    $configLines += @(
      "        - name: '$clusterName'",
      "          url: '$($connection.server)'",
      "          authProvider: serviceAccount",
      "          serviceAccountToken: '$token'",
      "          caData: '$($connection."certificate-authority-data")'",
      "          skipMetricsLookup: true"
    )
  }

  Set-Content -Path $temporaryConfig -Value ($configLines -join [Environment]::NewLine) -NoNewline

  Invoke-Kubectl -Arguments @(
    "--context", $ControlPlaneContext,
    "-n", $BackstageNamespace,
    "create", "secret", "generic", $ConfigSecretName,
    "--from-file=kubernetes-clusters.yaml=$temporaryConfig",
    "--dry-run=client", "-o", "yaml"
  ) -ErrorMessage "Could not render Backstage Kubernetes connection Secret." |
    & kubectl --context $ControlPlaneContext apply -f -

  if ($LASTEXITCODE -ne 0) {
    throw "Could not apply Backstage Kubernetes connection Secret '$BackstageNamespace/$ConfigSecretName'."
  }

  if ($AksDeployerGroupObjectId) {
    foreach ($clusterName in $AksClusterNames) {
      Invoke-Kubectl -Arguments @(
        "--context", $ControlPlaneContext,
        "-n", "argocd",
        "annotate", "secret", $clusterName,
        "platform_aks_deployer_group_object_id=$AksDeployerGroupObjectId",
        "--overwrite"
      ) -ErrorMessage "Could not annotate ArgoCD cluster Secret '$clusterName' with the AKS deployer group."
    }
  }

  Write-Output "Created $BackstageNamespace/$ConfigSecretName with $($TargetContexts.Count) read-only Backstage Kubernetes connections."
  Write-Output "Set backstage_kubernetes_clusters_secret_name = `"$ConfigSecretName`" in private tfvars and apply Terraform to mount this config."
} finally {
  Remove-Item $temporaryConfig -Force -ErrorAction SilentlyContinue
}
