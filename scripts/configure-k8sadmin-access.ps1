param(
  [string] $Context = "gitops-aks-admin",
  [string] $ArgoCdNamespace = "argocd",
  [string] $DevtronNamespace = "devtroncd",
  [string] $BackstageNamespace = "backstage",
  [string] $BackstageDeployment = "backstage-backstagechart",
  [string] $ControlPlaneClusterSecret = "gitops-aks",
  [string] $K8sAdminGroupName = "k8sadmin",
  [string] $KindDeployerGroupName = "akspe-kind-cluster-deployers",
  [string] $AksDeployerGroupName = "akspe-aks-cluster-deployers"
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param(
    [scriptblock] $Command,
    [string] $ErrorMessage
  )

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw $ErrorMessage
  }
}

function Get-EntraGroupId {
  param([string] $Name)

  $id = az ad group show --group $Name --query id -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
    throw "Could not resolve Entra group $Name."
  }
  return $id.Trim()
}

function Get-SecretText {
  param(
    [string] $Namespace,
    [string] $Name,
    [string] $Key
  )

  $secret = kubectl --context $Context -n $Namespace get secret $Name -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read secret $Namespace/$Name."
  }
  $encoded = $secret.data.$Key
  if ([string]::IsNullOrWhiteSpace($encoded)) {
    throw "Secret $Namespace/$Name does not contain key $Key."
  }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

function Get-DexConfigValue {
  param(
    [string] $Config,
    [string] $Key
  )

  $match = [regex]::Match($Config, "(?m)^\s*$([regex]::Escape($Key)):\s*(\S+)\s*$")
  if (-not $match.Success) {
    throw "Could not find $Key in Devtron dex.config."
  }
  return $match.Groups[1].Value.Trim('"', "'")
}

$k8sAdminGroupId = Get-EntraGroupId -Name $K8sAdminGroupName
$kindDeployerGroupId = Get-EntraGroupId -Name $KindDeployerGroupName
$aksDeployerGroupId = Get-EntraGroupId -Name $AksDeployerGroupName

$dexConfig = Get-SecretText -Namespace $DevtronNamespace -Name "devtron-secret" -Key "dex.config"
$issuer = Get-DexConfigValue -Config $dexConfig -Key "issuer"
$clientId = Get-DexConfigValue -Config $dexConfig -Key "clientID"
$clientSecret = Get-DexConfigValue -Config $dexConfig -Key "clientSecret"

Invoke-Checked -ErrorMessage "Failed to create/update $DevtronNamespace/platform-access-groups." -Command {
  kubectl --context $Context -n $DevtronNamespace create secret generic platform-access-groups `
    --from-literal=k8sadmin_group_object_id=$k8sAdminGroupId `
    --from-literal=kind_deployer_group_object_id=$kindDeployerGroupId `
    --from-literal=aks_deployer_group_object_id=$aksDeployerGroupId `
    --dry-run=client -o yaml |
    kubectl --context $Context apply -f -
}

$backstageDeploymentJson = kubectl --context $Context -n $BackstageNamespace get deployment $BackstageDeployment -o json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $null -ne $backstageDeploymentJson) {
  $backstageContainer = $backstageDeploymentJson.spec.template.spec.containers | Select-Object -First 1
  $currentAllowedGroups = $backstageContainer.env |
    Where-Object { $_.name -eq "BACKSTAGE_ALLOWED_GROUP_IDS" } |
    Select-Object -ExpandProperty value -First 1
  [string[]] $allowedGroups = @()
  if (-not [string]::IsNullOrWhiteSpace($currentAllowedGroups)) {
    $allowedGroups = @([regex]::Matches($currentAllowedGroups, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") |
      ForEach-Object { $_.Value.ToLowerInvariant() })
  }
  if ($allowedGroups -notcontains $k8sAdminGroupId) {
    $allowedGroups += $k8sAdminGroupId
  }
  $allowedGroupsValue = ($allowedGroups | Select-Object -Unique) -join ","
  Invoke-Checked -ErrorMessage "Failed to update Backstage allowed Entra groups." -Command {
    kubectl --context $Context -n $BackstageNamespace set env deployment/$BackstageDeployment BACKSTAGE_ALLOWED_GROUP_IDS=$allowedGroupsValue
  }
} else {
  Write-Warning "Backstage deployment $BackstageNamespace/$BackstageDeployment was not found; skipping Backstage allowed-group patch."
}

Invoke-Checked -ErrorMessage "Failed to patch ArgoCD cluster private platform annotations." -Command {
  kubectl --context $Context -n $ArgoCdNamespace annotate secret $ControlPlaneClusterSecret `
    platform_k8sadmin_group_object_id=$k8sAdminGroupId `
    platform_oidc_issuer=$issuer `
    platform_oidc_client_id=$clientId `
    --overwrite
}

Invoke-Checked -ErrorMessage "Failed to label the control-plane cluster Secret for platform access." -Command {
  kubectl --context $Context -n $ArgoCdNamespace label secret $ControlPlaneClusterSecret `
    platform_access_enabled=true `
    platform_cluster_type=aks `
    platform_devtron_visibility=aks `
    --overwrite
}

$arcClusterSecrets = kubectl --context $Context -n $ArgoCdNamespace get secret -l provider=arc -o json | ConvertFrom-Json
foreach ($clusterSecret in $arcClusterSecrets.items) {
  $name = $clusterSecret.metadata.name
  Invoke-Checked -ErrorMessage "Failed to label Arc cluster Secret $name for platform access." -Command {
    kubectl --context $Context -n $ArgoCdNamespace label secret $name `
      platform_access_enabled=true `
      platform_cluster_type=kind `
      platform_devtron_visibility=kind `
      --overwrite
  }
}

$aksClusterSecrets = kubectl --context $Context -n $ArgoCdNamespace get secret -l provider=aks -o json | ConvertFrom-Json
foreach ($clusterSecret in $aksClusterSecrets.items) {
  $name = $clusterSecret.metadata.name
  Invoke-Checked -ErrorMessage "Failed to label AKS cluster Secret $name for platform access." -Command {
    kubectl --context $Context -n $ArgoCdNamespace label secret $name `
      platform_access_enabled=true `
      platform_cluster_type=aks `
      platform_devtron_visibility=aks `
      --overwrite
  }
}

$managedClusterSecrets = kubectl --context $Context -n $ArgoCdNamespace get secret -l argocd.argoproj.io/secret-type=cluster -o json | ConvertFrom-Json
foreach ($clusterSecret in $managedClusterSecrets.items) {
  $name = $clusterSecret.metadata.name
  Invoke-Checked -ErrorMessage "Failed to annotate cluster Secret $name with private k8sadmin access input." -Command {
    kubectl --context $Context -n $ArgoCdNamespace annotate secret $name `
      platform_k8sadmin_group_object_id=$k8sAdminGroupId `
      platform_backstage_catalog_enabled=true `
      --overwrite
  }
}

$argoSecretPatch = @{
  stringData = @{
    "oidc.azure.clientSecret" = $clientSecret
  }
} | ConvertTo-Json -Depth 5 -Compress
$argoSecretPatchFile = New-TemporaryFile
Set-Content -Path $argoSecretPatchFile -Value $argoSecretPatch -NoNewline
Invoke-Checked -ErrorMessage "Failed to patch argocd-secret with OIDC client secret." -Command {
  kubectl --context $Context -n $ArgoCdNamespace patch secret argocd-secret --type merge --patch-file $argoSecretPatchFile
}
Remove-Item $argoSecretPatchFile -Force

foreach ($appName in @("cluster-addons", "cluster-apps", "addon-gitops-aks-argo-cd", "platform-access")) {
  $null = kubectl --context $Context -n $ArgoCdNamespace annotate application $appName argocd.argoproj.io/refresh=hard --overwrite
}

Write-Output "Private platform access inputs are configured for ArgoCD/GitOps reconciliation."
Write-Output "ArgoCD owns argocd-cm/argocd-rbac-cm through the addons-argocd ApplicationSet."
Write-Output "ArgoCD owns Devtron role convergence through the platform-access application."
Write-Output "Backstage allows k8sadmin through BACKSTAGE_ALLOWED_GROUP_IDS."
