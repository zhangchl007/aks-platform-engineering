<#
.SYNOPSIS
Creates the secret consumed by the ArgoCD-managed Backstage chart.

.DESCRIPTION
Reads the current Backstage Deployment only in memory and writes its required
runtime environment into backstage/backstage-runtime. It never prints secret
values. Run this before manually syncing the ArgoCD backstage Application.

Terraform must subsequently relinquish only helm_release.backstage from state;
do not run terraform destroy against the existing release.
#>
[CmdletBinding()]
param(
  [string] $Context = "gitops-aks-admin",
  [string] $Namespace = "backstage",
  [string] $Deployment = "backstage-backstagechart",
  [string] $SecretName = "backstage-runtime"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$existingSecret = kubectl --context $Context -n $Namespace get secret $SecretName --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) {
  throw "Could not check for existing secret $Namespace/$SecretName."
}
if ($existingSecret) {
  throw "Secret $Namespace/$SecretName already exists. Refusing to replace runtime credentials."
}

$deploymentObject = kubectl --context $Context -n $Namespace get deployment $Deployment -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
  throw "Could not read deployment $Namespace/$Deployment."
}

$container = @($deploymentObject.spec.template.spec.containers | Where-Object { $_.name -eq "backstagechart" }) |
  Select-Object -First 1
if (-not $container) {
  throw "Deployment $Namespace/$Deployment has no backstagechart container."
}

$requiredNames = @(
  "AZURE_TENANT_ID",
  "AZURE_CLIENT_ID",
  "AZURE_CLIENT_SECRET",
  "GITHUB_CLIENT_ID",
  "GITHUB_CLIENT_SECRET",
  "POSTGRES_HOST",
  "POSTGRES_PORT",
  "POSTGRES_USER",
  "POSTGRES_PASSWORD",
  "POSTGRES_DB",
  "BASE_URL",
  "K8S_CLUSTER_NAME",
  "K8S_CLUSTER_URL",
  "K8S_SERVICE_ACCOUNT_TOKEN",
  "GITHUB_TOKEN",
  "GITOPS_REPO"
)

$runtimeData = [ordered]@{}
foreach ($name in $requiredNames) {
  $environmentVariable = @($container.env | Where-Object { $_.name -eq $name }) | Select-Object -First 1
  if (-not $environmentVariable -or [string]::IsNullOrWhiteSpace($environmentVariable.value)) {
    throw "Deployment $Namespace/$Deployment does not expose a literal value for required runtime variable $name."
  }
  if ($environmentVariable.PSObject.Properties["valueFrom"]) {
    throw "Runtime variable $name uses valueFrom and must be migrated through its source secret instead."
  }
  $runtimeData[$name] = $environmentVariable.value
}

$manifest = @{
  apiVersion = "v1"
  kind       = "Secret"
  metadata   = @{
    name      = $SecretName
    namespace = $Namespace
    labels    = @{
      "app.kubernetes.io/name"       = "backstage"
      "platform-access.akspe.io/role" = "runtime-input"
    }
  }
  type       = "Opaque"
  stringData = $runtimeData
} | ConvertTo-Json -Depth 8

$manifest | kubectl --context $Context apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Could not create secret $Namespace/$SecretName."
}

Write-Output "Created $Namespace/$SecretName without writing credential values to output."
Write-Output "Next: sync the ArgoCD Application 'backstage', verify it is Healthy, then remove only helm_release.backstage[0] from Terraform state."
