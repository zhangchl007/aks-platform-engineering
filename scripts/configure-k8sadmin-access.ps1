param(
  [string] $Context = "gitops-aks-admin",
  [string] $K8sAdminGroupName = "k8sadmin",
  [string] $ArgoCdNamespace = "argocd",
  [string] $ArgoCdUrl = "https://172.179.107.194",
  [string] $ArgoCdServerDeployment = "argo-cd-argocd-server",
  [string] $DevtronNamespace = "devtroncd",
  [string] $DevtronDeployment = "devtron"
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

$k8sAdminGroupId = az ad group show --group $K8sAdminGroupName --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($k8sAdminGroupId)) {
  throw "Could not resolve Entra group $K8sAdminGroupName."
}

$dexConfig = Get-SecretText -Namespace $DevtronNamespace -Name "devtron-secret" -Key "dex.config"
$issuer = Get-DexConfigValue -Config $dexConfig -Key "issuer"
$clientId = Get-DexConfigValue -Config $dexConfig -Key "clientID"
$clientSecret = Get-DexConfigValue -Config $dexConfig -Key "clientSecret"

$argoSecretPatch = @{
  stringData = @{
    "oidc.azure.clientSecret" = $clientSecret
  }
} | ConvertTo-Json -Depth 5 -Compress
$argoSecretPatchFile = New-TemporaryFile
Set-Content -Path $argoSecretPatchFile -Value $argoSecretPatch -NoNewline
Invoke-Checked -ErrorMessage "Failed to patch argocd-secret." -Command {
  kubectl --context $Context -n $ArgoCdNamespace patch secret argocd-secret --type merge --patch-file $argoSecretPatchFile
}
Remove-Item $argoSecretPatchFile -Force

$oidcConfig = @"
name: Microsoft Entra ID
issuer: $issuer
clientID: $clientId
clientSecret: `$oidc.azure.clientSecret
requestedScopes: ["openid", "profile", "email"]
requestedIDTokenClaims:
  groups:
    essential: true
"@

$argoCmPatch = @{
  data = @{
    "url" = $ArgoCdUrl
    "oidc.config" = $oidcConfig
  }
} | ConvertTo-Json -Depth 8 -Compress
$argoCmPatchFile = New-TemporaryFile
Set-Content -Path $argoCmPatchFile -Value $argoCmPatch -NoNewline
Invoke-Checked -ErrorMessage "Failed to patch argocd-cm." -Command {
  kubectl --context $Context -n $ArgoCdNamespace patch configmap argocd-cm --type merge --patch-file $argoCmPatchFile
}
Remove-Item $argoCmPatchFile -Force

$currentPolicy = kubectl --context $Context -n $ArgoCdNamespace get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}'
if ($LASTEXITCODE -ne 0) {
  throw "Failed to read argocd-rbac-cm."
}
$adminPolicyLine = "g, $k8sAdminGroupId, role:admin"
$policyLines = @($currentPolicy -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($policyLines -notcontains $adminPolicyLine) {
  $policyLines += $adminPolicyLine
}
$rbacPatch = @{
  data = @{
    "policy.csv" = (($policyLines | Select-Object -Unique) -join "`n") + "`n"
    "policy.default" = ""
    "scopes" = "[groups]"
  }
} | ConvertTo-Json -Depth 8 -Compress
$rbacPatchFile = New-TemporaryFile
Set-Content -Path $rbacPatchFile -Value $rbacPatch -NoNewline
Invoke-Checked -ErrorMessage "Failed to patch argocd-rbac-cm." -Command {
  kubectl --context $Context -n $ArgoCdNamespace patch configmap argocd-rbac-cm --type merge --patch-file $rbacPatchFile
}
Remove-Item $rbacPatchFile -Force

Invoke-Checked -ErrorMessage "Failed to restart ArgoCD server." -Command {
  kubectl --context $Context -n $ArgoCdNamespace rollout restart deployment/$ArgoCdServerDeployment
}
Invoke-Checked -ErrorMessage "ArgoCD server rollout did not complete." -Command {
  kubectl --context $Context -n $ArgoCdNamespace rollout status deployment/$ArgoCdServerDeployment --timeout=180s
}

$postgresSecret = kubectl --context $Context -n $DevtronNamespace get secret postgresql-postgresql -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
  throw "Failed to read Devtron PostgreSQL secret."
}
$postgresPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($postgresSecret.data.'postgresql-password'))
$postgresDb = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($postgresSecret.data.POSTGRES_DB))

$sql = @"
DO `$`$
DECLARE
  rg_id integer;
  super_role_id integer;
BEGIN
  SELECT id INTO super_role_id FROM roles WHERE role = 'role:super-admin___' LIMIT 1;
  IF super_role_id IS NULL THEN
    RAISE EXCEPTION 'Devtron super-admin role not found';
  END IF;

  SELECT id INTO rg_id FROM role_group WHERE name = '$k8sAdminGroupId' OR casbin_name = 'group:$k8sAdminGroupId' LIMIT 1;
  IF rg_id IS NULL THEN
    INSERT INTO role_group (name, casbin_name, description, created_by, updated_by, created_on, updated_on, active)
    VALUES ('$k8sAdminGroupId', 'group:$k8sAdminGroupId', '${K8sAdminGroupName}: Devtron platform administrator group', 1, 1, now(), now(), true)
    RETURNING id INTO rg_id;
  ELSE
    UPDATE role_group
    SET name = '$k8sAdminGroupId',
        casbin_name = 'group:$k8sAdminGroupId',
        description = '${K8sAdminGroupName}: Devtron platform administrator group',
        active = true,
        updated_by = 1,
        updated_on = now()
    WHERE id = rg_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM role_group_role_mapping WHERE role_group_id = rg_id AND role_id = super_role_id) THEN
    INSERT INTO role_group_role_mapping (role_group_id, role_id, created_by, updated_by, created_on, updated_on)
    VALUES (rg_id, super_role_id, 1, 1, now(), now());
  END IF;
END
`$`$;
"@

$sql | kubectl --context $Context -n $DevtronNamespace exec -i postgresql-postgresql-0 -c postgres -- env "PGPASSWORD=$postgresPassword" psql -U postgres -d $postgresDb -v ON_ERROR_STOP=1
if ($LASTEXITCODE -ne 0) {
  throw "Failed to configure Devtron k8sadmin role group."
}

Invoke-Checked -ErrorMessage "Failed to restart Devtron." -Command {
  kubectl --context $Context -n $DevtronNamespace rollout restart deployment/$DevtronDeployment
}
Invoke-Checked -ErrorMessage "Devtron rollout did not complete." -Command {
  kubectl --context $Context -n $DevtronNamespace rollout status deployment/$DevtronDeployment --timeout=180s
}

Write-Output "Configured $K8sAdminGroupName as ArgoCD role:admin and Devtron super-admin."
