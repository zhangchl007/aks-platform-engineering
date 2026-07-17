<#
.SYNOPSIS
Configures the platform Entra groups and ArgoCD/Backstage private access inputs.

.DESCRIPTION
This script does not deploy or configure any external delivery product. It keeps
the common Backstage sign-in group, target cluster RBAC annotations, and ArgoCD
OIDC client secret aligned with the supplied Entra application.
#>
[CmdletBinding()]
param(
  [string] $Context = "gitops-aks-admin",
  [string] $ArgoCdNamespace = "argocd",
  [string] $BackstageNamespace = "backstage",
  [string] $BackstageSsoGroupName = "akspe-backstage-users",
  [string] $K8sAdminGroupName = "k8sadmin",
  [string] $KindDeployerGroupName = "akspe-kind-cluster-deployers",
  [string] $AksDeployerGroupName = "akspe-aks-cluster-deployers",
  [string] $DefaultAksDeploymentClusterName = "gitops-aks",
  [Parameter(Mandatory = $true)][string] $EntraClientId,
  [Parameter(Mandatory = $true)][string] $EntraClientSecret,
  [string] $EntraIssuer
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
  param([scriptblock] $Command, [string] $ErrorMessage)

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw $ErrorMessage
  }
}

function Get-EntraGroupId {
  param([string] $Name, [switch] $CreateIfMissing)

  $id = az ad group show --group $Name --query id -o tsv
  if (($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) -and $CreateIfMissing) {
    $mailNickname = ($Name -replace "[^A-Za-z0-9]", "").ToLowerInvariant()
    $id = az ad group create --display-name $Name --mail-nickname $mailNickname --query id -o tsv
  }
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
    throw "Could not resolve Entra group $Name."
  }
  return $id.Trim()
}

function Add-EntraGroupMemberIfMissing {
  param([string] $GroupId, [string] $MemberId)

  $isMember = az ad group member check --group $GroupId --member-id $MemberId --query value -o tsv
  if ($LASTEXITCODE -ne 0) {
    throw "Could not check whether $MemberId is a member of $GroupId."
  }
  if ($isMember -ne "true") {
    az ad group member add --group $GroupId --member-id $MemberId
    if ($LASTEXITCODE -ne 0) {
      throw "Could not add $MemberId to Entra group $GroupId."
    }
  }

}

function ConvertTo-BackstageEntityName {
  param([string] $Name)

  return (($Name.Trim().ToLowerInvariant()) -replace "[^a-z0-9-]", "-").Trim("-")
}

function Set-EnterpriseAppAssignmentRequired {
  param([string] $ClientId)

  $servicePrincipalId = az ad sp show --id $ClientId --query id -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($servicePrincipalId)) {
    throw "Could not resolve Enterprise Application service principal for client ID $ClientId."
  }

  $patchBodyFile = New-TemporaryFile
  try {
    @{ appRoleAssignmentRequired = $true } | ConvertTo-Json -Compress | Set-Content -Path $patchBodyFile -NoNewline
    az rest --method PATCH `
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$servicePrincipalId" `
      --headers "Content-Type=application/json" `
      --body "@$patchBodyFile" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not enable assignment-required on Enterprise Application $servicePrincipalId."
    }
  } finally {
    Remove-Item $patchBodyFile -Force -ErrorAction SilentlyContinue
  }
  return $servicePrincipalId.Trim()
}

function Add-EnterpriseAppGroupAssignmentIfMissing {
  param([string] $ServicePrincipalId, [string] $GroupId)

  $assignments = az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ServicePrincipalId/appRoleAssignedTo" -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) {
    throw "Could not list Enterprise Application assignments for $ServicePrincipalId."
  }
  if ($assignments.value | Where-Object { $_.principalId -eq $GroupId -and $_.resourceId -eq $ServicePrincipalId } | Select-Object -First 1) {
    return
  }

  $bodyFile = New-TemporaryFile
  try {
    @{ principalId = $GroupId; resourceId = $ServicePrincipalId; appRoleId = "00000000-0000-0000-0000-000000000000" } |
      ConvertTo-Json -Compress | Set-Content -Path $bodyFile -NoNewline
    az rest --method POST `
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ServicePrincipalId/appRoleAssignedTo" `
      --headers "Content-Type=application/json" `
      --body "@$bodyFile" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not assign group $GroupId to Enterprise Application $ServicePrincipalId."
    }
  } finally {
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
  }
}

function Set-ApplicationGroupClaims {
  param([string] $ClientId)

  $application = az ad app show --id $ClientId -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($application.id)) {
    throw "Could not resolve the Backstage application registration for client ID $ClientId."
  }

  $patchBodyFile = New-TemporaryFile
  try {
    @{ groupMembershipClaims = "ApplicationGroup" } | ConvertTo-Json -Compress |
      Set-Content -Path $patchBodyFile -NoNewline
    az rest --method PATCH `
      --uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
      --headers "Content-Type=application/json" `
      --body "@$patchBodyFile" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not configure application-scoped Entra group claims for Backstage."
    }
  } finally {
    Remove-Item $patchBodyFile -Force -ErrorAction SilentlyContinue
  }
}

function Set-MicrosoftGraphOrganizationPermissions {
  param([string] $ClientId)

  $graphApplicationId = "00000003-0000-0000-c000-000000000000"
  $permissions = @(
    "df021288-bdef-4463-88db-98f22de89214=Role", # User.Read.All
    "98830695-27a2-44f7-8c18-0c3ebc9698f6=Role"  # GroupMember.Read.All
  )
  az ad app permission add --id $ClientId --api $graphApplicationId --api-permissions $permissions
  if ($LASTEXITCODE -ne 0) {
    throw "Could not add Microsoft Graph organization read permissions to Backstage."
  }

  az ad app permission admin-consent --id $ClientId
  if ($LASTEXITCODE -ne 0) {
    throw "Could not grant administrator consent for Backstage Microsoft Graph permissions."
  }
}

$k8sAdminGroupId = Get-EntraGroupId -Name $K8sAdminGroupName
$kindDeployerGroupId = Get-EntraGroupId -Name $KindDeployerGroupName
$aksDeployerGroupId = Get-EntraGroupId -Name $AksDeployerGroupName
$backstageSsoGroupId = Get-EntraGroupId -Name $BackstageSsoGroupName -CreateIfMissing

foreach ($memberGroupId in @($k8sAdminGroupId, $kindDeployerGroupId, $aksDeployerGroupId)) {
  Add-EntraGroupMemberIfMissing -GroupId $backstageSsoGroupId -MemberId $memberGroupId
}

if (-not $EntraIssuer) {
  $tenantId = az account show --query tenantId -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenantId)) {
    throw "Could not resolve the Entra tenant ID. Pass -EntraIssuer explicitly."
  }
  $EntraIssuer = "https://login.microsoftonline.com/$tenantId/v2.0"
}

$backstageServicePrincipalId = Set-EnterpriseAppAssignmentRequired -ClientId $EntraClientId
foreach ($assignedGroupId in @($backstageSsoGroupId, $k8sAdminGroupId, $kindDeployerGroupId, $aksDeployerGroupId)) {
  Add-EnterpriseAppGroupAssignmentIfMissing -ServicePrincipalId $backstageServicePrincipalId -GroupId $assignedGroupId
}
Set-ApplicationGroupClaims -ClientId $EntraClientId
Set-MicrosoftGraphOrganizationPermissions -ClientId $EntraClientId

$backstageSsoGroupEntityName = ConvertTo-BackstageEntityName -Name $BackstageSsoGroupName
$k8sAdminGroupEntityName = ConvertTo-BackstageEntityName -Name $K8sAdminGroupName
$kindDeployerGroupEntityName = ConvertTo-BackstageEntityName -Name $KindDeployerGroupName
$aksDeployerGroupEntityName = ConvertTo-BackstageEntityName -Name $AksDeployerGroupName

$groupMappingsTable = [ordered]@{}
$groupMappingsTable[$backstageSsoGroupId] = $backstageSsoGroupEntityName
$groupMappingsTable[$k8sAdminGroupId] = $k8sAdminGroupEntityName
$groupMappingsTable[$kindDeployerGroupId] = $kindDeployerGroupEntityName
$groupMappingsTable[$aksDeployerGroupId] = $aksDeployerGroupEntityName
$groupMappings = $groupMappingsTable | ConvertTo-Json -Compress
$graphGroupFilter = (@($backstageSsoGroupId, $k8sAdminGroupId, $kindDeployerGroupId, $aksDeployerGroupId) |
  ForEach-Object { "id eq '$_'" }) -join " or "
$graphUserGroupFilter = "id eq '$backstageSsoGroupId'"

Invoke-Checked -ErrorMessage "Failed to create/update $BackstageNamespace/platform-backstage-sso." -Command {
  @{
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = @{
      name      = "platform-backstage-sso"
      namespace = $BackstageNamespace
    }
    type       = "Opaque"
    stringData = @{
      backstage_sso_group_object_id   = $backstageSsoGroupId
      backstage_entra_group_mappings  = $groupMappings
      backstage_graph_group_filter    = $graphGroupFilter
      backstage_graph_user_group_filter = $graphUserGroupFilter
      backstage_admin_group_object_ids = $k8sAdminGroupId
      backstage_admin_group_entity_names = $k8sAdminGroupEntityName
    }
  } | ConvertTo-Json -Depth 6 | kubectl --context $Context apply -f -
}

$managedClusterSecrets = kubectl --context $Context -n $ArgoCdNamespace get secret -l argocd.argoproj.io/secret-type=cluster -o json | ConvertFrom-Json
foreach ($clusterSecret in $managedClusterSecrets.items) {
  $name = $clusterSecret.metadata.name
  $clusterType = $clusterSecret.metadata.labels.platform_cluster_type
  Invoke-Checked -ErrorMessage "Failed to annotate cluster Secret $name with private platform access inputs." -Command {
    kubectl --context $Context -n $ArgoCdNamespace annotate secret $name `
      platform_k8sadmin_group_object_id=$k8sAdminGroupId `
      platform_aks_deployer_group_object_id=$aksDeployerGroupId `
      platform_backstage_catalog_enabled=true `
      --overwrite
  }
  if ($name -eq $DefaultAksDeploymentClusterName) {
    Invoke-Checked -ErrorMessage "Failed to label cluster Secret $name as the default approved AKS deployment target." -Command {
      kubectl --context $Context -n $ArgoCdNamespace label secret $name `
        platform_access_enabled=true `
        platform_cluster_type=aks `
        platform_access_deployment_enabled=true `
        --overwrite
    }
    $clusterType = "aks"
  }
  if (-not $clusterType) {
    Write-Warning "Cluster Secret '$name' has no platform_cluster_type label and will not receive a target baseline."
  }
}

$argoSecretPatchFile = New-TemporaryFile
try {
  @{
    stringData = @{
      "oidc.azure.clientSecret" = $EntraClientSecret
      "oidc.azure.issuer"       = $EntraIssuer
    }
  } | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $argoSecretPatchFile -NoNewline
  Invoke-Checked -ErrorMessage "Failed to patch argocd-secret with Entra OIDC configuration." -Command {
    kubectl --context $Context -n $ArgoCdNamespace patch secret argocd-secret --type merge --patch-file $argoSecretPatchFile
  }
} finally {
  Remove-Item $argoSecretPatchFile -Force -ErrorAction SilentlyContinue
}

foreach ($appName in @("cluster-addons", "cluster-apps", "addon-gitops-aks-argo-cd", "platform-access")) {
  $null = kubectl --context $Context -n $ArgoCdNamespace annotate application $appName argocd.argoproj.io/refresh=hard --overwrite
}

Write-Output "Private platform access inputs are configured for ArgoCD and Backstage."
Write-Output "The shared Backstage Enterprise Application requires assignment and is assigned to $BackstageSsoGroupName."
Write-Output "Backstage allows the common $BackstageSsoGroupName group and resolves approved Entra role groups through Microsoft Graph."
