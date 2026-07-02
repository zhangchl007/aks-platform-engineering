# Backstage Terraform Recreate Troubleshooting

This runbook records the issues found while destroying and recreating the AKS
platform engineering demo with Terraform and Backstage enabled.

> Do not paste GitHub tokens, Entra client secrets, service account tokens, or
> Terraform state output into tickets or chat. Use Terraform sensitive variables
> and short-lived app credentials.

## Environment

| Item | Value |
| --- | --- |
| Resource group | `aks-gitops` |
| AKS cluster | `gitops-aks` |
| Fleet Manager | `gitops-fleet` |
| Backstage namespace | `backstage` |
| Backstage service | `backstage-backstagechart` |
| Backstage public IP | `20.10.37.171` |
| Backstage URL | `https://20.10.37.171` |
| Git branch | `zhangchl007-azure-arc-onboarding` |
| Backstage Entra app | `Backstage-aks-gitops` |

## Final known-good state

Validation commands:

```powershell
$env:KUBECONFIG = ".\terraform\kubeconfig"

kubectl get nodes
kubectl get pods -n argocd
kubectl get pods,svc -n backstage -o wide
az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table
```

Expected:

- `gitops-aks` nodes are `Ready`.
- Argo CD pods in `argocd` are `Running`.
- Backstage pod in `backstage` is `1/1 Running`.
- Fleet member `control-plane` is `Succeeded`.
- Backstage service has external IP `20.10.37.171`.

## Terraform fixes made

### Backstage must be explicitly enabled

Backstage is not deployed by default. Use:

```powershell
terraform -chdir=terraform apply `
  -var build_backstage=true `
  -var location=eastus2 `
  -var postgres_location=westus3 `
  -var gitops_addons_org=https://github.com/zhangchl007 `
  -var gitops_addons_revision=zhangchl007-azure-arc-onboarding
```

### AKS node SKU was unavailable in `eastus2`

Symptom:

```text
The VM size of Standard_D2s_v3 is not allowed in your subscription in location 'eastus2'
```

Fix:

- Changed Terraform default `agents_size` from `Standard_D2s_v3` to
  `Standard_D2_v3`.

### PostgreSQL Flexible Server was restricted in `eastus2`

Symptom:

```text
LocationIsOfferRestricted: Subscriptions are restricted from provisioning in location 'eastus2'
```

Fix:

- Added `postgres_location`.
- Used `westus3` for the Backstage PostgreSQL Flexible Server.
- Made the PostgreSQL server name region-specific:
  `aks-gitops-backstage-postgresql-westus3`.

### PostgreSQL name collision after failed create

Symptom:

```text
InvalidResourceLocation: The resource already exists in location 'eastus2'
```

Cause:

- A failed PostgreSQL create reserved the original name in `eastus2`.

Fix:

- Changed the server name to include the region suffix.

### Backstage Helm values exposed secret-shaped values in plans

Symptoms:

- Terraform plan showed placeholder secret values in Helm metadata.
- Backstage required non-empty GitHub token and Microsoft client secret values.

Fix:

- Marked `github_token` as sensitive.
- Used `set_sensitive` for:
  - `env.GITHUB_TOKEN`
  - `env.AZURE_CLIENT_SECRET`
  - `env.POSTGRES_PASSWORD`
  - `env.K8S_SERVICE_ACCOUNT_TOKEN`

Never print token values. Use process environment variables or Terraform
sensitive variables.

## GitHub CLI token setup

### `gh` not found

Symptom:

```text
gh : The term 'gh' is not recognized
```

Found CLI location:

```powershell
C:\Users\Jimmyzhang\AppData\Local\copilot-desktop-gh-2.95.0\gh.exe
```

Temporary PATH fix:

```powershell
$env:Path = "C:\Users\Jimmyzhang\AppData\Local\copilot-desktop-gh-2.95.0;$env:Path"
gh --version
gh auth status
```

Permanent user PATH fix:

```powershell
$ghPath = "C:\Users\Jimmyzhang\AppData\Local\copilot-desktop-gh-2.95.0"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$userPath;$ghPath", "User")
```

Open a new PowerShell session after updating the user PATH.

### Get a GitHub token without exposing it

Do not echo the token. Use it only as an environment variable for Terraform:

```powershell
$env:GITHUB_TOKEN = gh auth token
$env:TF_VAR_github_token = $env:GITHUB_TOKEN

terraform -chdir=terraform apply `
  -var build_backstage=true `
  -var location=eastus2 `
  -var postgres_location=westus3 `
  -var gitops_addons_org=https://github.com/zhangchl007 `
  -var gitops_addons_revision=zhangchl007-azure-arc-onboarding

Remove-Item Env:\TF_VAR_github_token -ErrorAction SilentlyContinue
Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
```

## Entra app registration and 30-day secret

The original `Backstage` app registration could be read but not updated by the
current identity.

Symptoms:

```text
Authorization_RequestDenied: Insufficient privileges to complete the operation
```

This happened when trying to:

- add redirect URIs,
- add app passwords,
- modify app roles.

Workaround:

- Created a new app registration owned by the current identity:
  `Backstage-aks-gitops`.
- Added redirect URI:
  `https://20.10.37.171/api/auth/microsoft/handler/frame`.
- Created a client secret with a 30-day expiry.
- Passed the client ID and secret to Backstage through Terraform sensitive vars.

Create or rotate the 30-day secret without printing it:

```powershell
$appId = "<Backstage-aks-gitops-app-id>"
$endDate = (Get-Date).ToUniversalTime().AddDays(30).ToString("yyyy-MM-ddTHH:mm:ssZ")
$secret = az ad app credential reset --id $appId --append --end-date $endDate --query password -o tsv

$env:TF_VAR_backstage_azure_client_id = $appId
$env:TF_VAR_backstage_azure_client_secret = $secret

terraform -chdir=terraform apply `
  -var build_backstage=true `
  -var manage_backstage_entra_credentials=false `
  -var location=eastus2 `
  -var postgres_location=westus3 `
  -var gitops_addons_org=https://github.com/zhangchl007 `
  -var gitops_addons_revision=zhangchl007-azure-arc-onboarding

Remove-Item Env:\TF_VAR_backstage_azure_client_id -ErrorAction SilentlyContinue
Remove-Item Env:\TF_VAR_backstage_azure_client_secret -ErrorAction SilentlyContinue
$secret = $null
```

Validate expiry without showing the secret:

```powershell
az ad app credential list --id <Backstage-aks-gitops-app-id> `
  --query "[].{displayName:displayName,endDateTime:endDateTime}" -o table
```

## Backstage startup failures

### Empty GitHub token and Microsoft client secret

Symptoms in Backstage pod logs:

```text
Invalid type in config for key 'integrations.github[0].token', got empty-string
Invalid type in config for key 'auth.providers.microsoft.development.clientSecret', got empty-string
Backend startup failed
```

Fix:

- Provide a non-empty GitHub token from `gh auth token`.
- Provide a non-empty Backstage Entra client secret.
- Ensure the Helm values are applied with `set_sensitive`.

Validation:

```powershell
$env:KUBECONFIG = ".\terraform\kubeconfig"
$pod = kubectl get pods -n backstage -l app.kubernetes.io/instance=backstage -o jsonpath='{.items[0].metadata.name}'
kubectl logs $pod -n backstage --tail=200
```

Expected logs:

```text
Found 4 new secrets in config that will be redacted
Configuring auth provider: microsoft
```

## Backstage network troubleshooting

### What was healthy

Kubernetes service and endpoints were healthy:

```powershell
kubectl get svc -n backstage backstage-backstagechart -o wide
kubectl get endpoints -n backstage backstage-backstagechart -o yaml
```

Expected:

- Service type `LoadBalancer`.
- External IP `20.10.37.171`.
- Endpoint points to the Backstage pod on port `7007`.

Backstage was reachable from inside the cluster:

```powershell
kubectl run backstage-curl-check --rm -i --restart=Never `
  --image=curlimages/curl:8.10.1 --command -- `
  curl -k -I --max-time 15 https://backstage-backstagechart.backstage.svc.cluster.local
```

Backstage was also reachable through nodePort from inside the cluster:

```powershell
kubectl run curl-nodeport --rm -i --restart=Never `
  --image=curlimages/curl:8.10.1 --command -- `
  curl -k -I --max-time 15 https://10.52.0.4:31795
```

### What was not healthy

Local machine could not connect to the public IP:

```powershell
Test-NetConnection 20.10.37.171 -Port 443
curl.exe -k -I --max-time 30 https://20.10.37.171
```

Result:

```text
TcpTestSucceeded: False
curl: Failed to connect to 20.10.37.171 port 443
```

### NSG, peering, and route checks

VNet peering:

```powershell
az network vnet peering list -g aks-gitops --vnet-name vnet1 -o table
```

Result:

- No VNet peerings.
- No peering issue found.

Route table:

```powershell
az network route-table list -g aks-gitops -o table
```

Result:

- No custom route tables.
- No UDR issue found.

Subnet NSG:

```powershell
az network vnet subnet show -g aks-gitops --vnet-name vnet1 -n aks `
  --query "{nsg:networkSecurityGroup.id,routeTable:routeTable.id}" -o json
```

Result:

- Subnet has NSG `vnet1-aks-nsg-eastus2`.
- No custom route table.

Node resource group NSG:

```powershell
az network nsg list -g MC_aks-gitops_gitops-aks_eastus2 `
  --query "[].{name:name,rules:securityRules[].{name:name,priority:priority,direction:direction,access:access,protocol:protocol,destinationPortRanges:destinationPortRanges,sourceAddressPrefix:sourceAddressPrefix}}" -o json
```

Temporary diagnostic rules added:

- `Allow-Backstage-NodePort-31795` on node resource group NSG.
- `Allow-Backstage-NodePort-31795` on subnet NSG.

These did not restore local-to-public-IP access.

### Azure Load Balancer findings

Inspect rules and probes:

```powershell
$nodeRg = "MC_aks-gitops_gitops-aks_eastus2"

az network lb rule list -g $nodeRg --lb-name kubernetes `
  --query "[].{name:name,frontendPort:frontendPort,backendPort:backendPort,probe:probe.id,frontend:frontendIPConfiguration.id}" -o json

az network lb probe list -g $nodeRg --lb-name kubernetes `
  --query "[].{name:name,protocol:protocol,port:port,requestPath:requestPath}" -o json
```

Finding:

- Probe was using the service nodePort `31795`.
- Initial LB rule forwarded frontend `443` to backend `443`.
- Nodes were not listening on `443`.
- Backstage was listening via nodePort `31795`.

Manual diagnostic patch:

```powershell
az network lb rule update `
  -g MC_aks-gitops_gitops-aks_eastus2 `
  --lb-name kubernetes `
  -n a0e3a540ea4884cb98af380f43d52e18-TCP-443 `
  --backend-port 31795
```

After patch:

- Public IP worked from inside the cluster.
- Public IP still failed from the local machine.

Conclusion:

- Backstage pod, ClusterIP service, nodePort, and Azure-internal public-IP path
  were working.
- No VNet peering or route table issue was found.
- Remaining local access issue appears to be outside the Kubernetes service path,
  such as client network path, public IP policy, corporate network filtering, or
  an Azure public IP reachability constraint.

## Useful validation commands

```powershell
# Backstage workload
$env:KUBECONFIG = ".\terraform\kubeconfig"
kubectl rollout status deployment/backstage-backstagechart -n backstage --timeout=180s
kubectl get pods,svc,endpoints -n backstage -o wide

# Backstage logs
$pod = kubectl get pods -n backstage -l app.kubernetes.io/instance=backstage -o jsonpath='{.items[0].metadata.name}'
kubectl logs $pod -n backstage --tail=200

# Argo CD
kubectl get pods -n argocd
kubectl get svc -n argocd

# Fleet
az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table

# Entra app
az ad app show --id <Backstage-aks-gitops-app-id> `
  --query "{appId:appId,displayName:displayName,redirectUris:web.redirectUris}" -o json

az ad app credential list --id <Backstage-aks-gitops-app-id> `
  --query "[].{displayName:displayName,endDateTime:endDateTime}" -o table

# GitHub CLI
gh --version
gh auth status
```

## Cleanup notes

Remove temporary Terraform plan files after applies because they may contain
sensitive values:

```powershell
Get-ChildItem .\terraform -File |
  Where-Object { $_.Name -match '^tfapplybackstage' } |
  Remove-Item -Force
```

Do not commit:

- Terraform plan files,
- kubeconfigs,
- tokens,
- app secrets,
- Terraform state files.

