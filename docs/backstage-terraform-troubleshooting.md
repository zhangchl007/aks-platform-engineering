# Backstage Terraform Recreate Troubleshooting

This runbook records the issues found while destroying and recreating the AKS
platform engineering demo with Terraform and Backstage enabled.

> Do not paste GitHub tokens, Entra client secrets, service account tokens, or
> Terraform state output into tickets or chat. Use Terraform sensitive variables
> and short-lived app credentials.

> Current final working deployment uses **GitHub OAuth** and public IP
> **`20.246.0.45`**. Older sections about the earlier Entra-based recreate and
> the previous public IP are kept as historical notes, but the summary and
> commands below reflect the final corrected deployment path.

## Environment

| Item | Value |
| --- | --- |
| Resource group | `aks-gitops` |
| AKS cluster | `gitops-aks` |
| Fleet Manager | `gitops-fleet` |
| Backstage namespace | `backstage` |
| Backstage service | `backstage-backstagechart` |
| Backstage public IP | `20.246.0.45` |
| Backstage URL | `https://20.246.0.45` |
| Git branch | `zhangchl007-azure-arc-onboarding` |
| Backstage auth mode | `GitHub OAuth` |
| Backstage image | `amllearning02.azurecr.io/backstage:github-idp-fix2` |

## Latest final rerun summary (2026-07)

This was the last, fully corrected deployment path used for the customer demo.

### What made the last deployment take too long

| Root cause | Why it consumed time | Final fix |
| --- | --- | --- |
| `build_backstage=false` was used during one apply | In this repo, `build_backstage` does **not** only control image build. It gates the full Backstage stack, so Terraform wanted to destroy Backstage resources. | Always pass `-var build_backstage=true` for Backstage work. |
| Backstage package versions drifted apart | `@backstage/backend-plugin-api` resolved to multiple incompatible versions (`0.8.1` and `1.3.0`), causing `ServiceRegistry.get` / `BackendInitializer` startup crashes. | Pin all `@backstage/*` packages to the 1.32.2-compatible set via `resolutions`, then regenerate `yarn.lock`. |
| Windows PowerShell wrote `package.json` with a BOM | ACR build failed at `yarn build:backend`, and Azure CLI log streaming also tripped over the BOM on Windows. | Strip the BOM and write JSON files with UTF-8 **without** BOM. |
| Terraform Helm release pointed to an old remote OCI chart | The remote chart did not contain `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` env mappings, so Terraform variables never reached the container. | Point `helm_release.backstage` at the local chart path `../backstage/backstagechart`. |
| Helm release got stuck in `pending-upgrade` | Later applies could not move the release forward, so new OAuth values never rolled out. | Delete the orphaned Helm release secret (`sh.helm.release.v1.backstage.v4`) and re-apply. |
| Static TLS secret had an expired certificate | Backstage started, but internal calls logged `CERT_HAS_EXPIRED`, and the deployment remained noisy and misleading. | Replace file-based TLS secret input with Terraform-managed `tls_self_signed_cert`. |
| Subnet NSG had no inbound 443 allow rule | Backstage was healthy in-cluster, but the public IP still returned connection failures from the local machine. | Add an inbound allow rule on `vnet1-aks-nsg-eastus2` for TCP/443 from `Internet`. |

### Current known-good Terraform apply

```powershell
$env:GITHUB_TOKEN = gh auth token
$env:TF_VAR_github_token = $env:GITHUB_TOKEN
$env:TF_VAR_backstage_github_client_id = "<github-oauth-client-id>"
$env:TF_VAR_backstage_github_client_secret = "<github-oauth-client-secret>"

terraform -chdir=terraform apply `
  -var build_backstage=true `
  -var gitops_addons_org=https://github.com/zhangchl007 `
  -var gitops_addons_revision=zhangchl007-azure-arc-onboarding `
  -var backstage_image_repository=amllearning02.azurecr.io/backstage `
  -var backstage_image_tag=github-idp-fix2
```

### Current known-good validation

```powershell
kubectl --context gitops-aks get pods -n backstage
kubectl --context gitops-aks get svc -n backstage backstage-backstagechart -o wide

$pod = kubectl --context gitops-aks -n backstage get pods `
  -l app.kubernetes.io/name=backstagechart `
  -o jsonpath='{.items[0].metadata.name}'

kubectl --context gitops-aks -n backstage logs $pod --tail=200
curl.exe -k -I --max-time 20 https://20.246.0.45
curl.exe -k -I --max-time 20 "https://20.246.0.45/api/auth/github/start?env=development"
```

Expected:

- Backstage pod is `1/1 Running`.
- Logs contain `Configuring auth provider: github`.
- `https://20.246.0.45` returns `HTTP 200`.
- `/api/auth/github/start?env=development` returns `HTTP 302`.

## Final known-good state

Validation commands:

```powershell
$env:KUBECONFIG = ".\terraform\kubeconfig"

kubectl get nodes
kubectl get pods -n argocd
kubectl get pods,svc -n backstage -o wide
curl.exe -k -I --max-time 20 https://20.246.0.45
curl.exe -k -I --max-time 20 "https://20.246.0.45/api/auth/github/start?env=development"
az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table
```

Expected:

- `gitops-aks` nodes are `Ready`.
- Argo CD pods in `argocd` are `Running`.
- Backstage pod in `backstage` is `1/1 Running`.
- Fleet member `control-plane` is `Succeeded`.
- Backstage service has external IP `20.246.0.45`.
- Public root URL returns `200`.
- GitHub auth start endpoint returns `302`.

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

### `build_backstage` gates the whole Backstage stack

Symptom:

- A targeted apply looked like it wanted to destroy Backstage resources instead
  of only updating the image or Helm values.

Cause:

- In this repo, `local.build_backstage = var.build_backstage` controls the full
  Backstage resource set, including namespace, database, secrets, and Helm
  release.

Fix:

- Always pass `-var build_backstage=true` for any Backstage Terraform apply.

### Local chart is required for GitHub OAuth values

Symptom:

```text
Failed to initialize github auth provider
Missing required config value at 'auth.providers.github.development.clientId'
```

Cause:

- `terraform/main.tf` originally pointed `helm_release.backstage` to the remote
  OCI chart `oci://oowcontainerimages.azurecr.io/helm` version `0.1.0`.
- That chart did not include `GITHUB_CLIENT_ID` and
  `GITHUB_CLIENT_SECRET` environment-variable wiring, so Terraform `set` /
  `set_sensitive` values never reached the container.

Fix:

- Point `helm_release.backstage` to the local chart path:

```hcl
chart = "${path.module}/../backstage/backstagechart"
```

### Helm release stuck in `pending-upgrade`

Symptom:

- Terraform apply waited on the Helm release but the deployment never picked up
  the new OAuth values.

Cause:

- A timed-out upgrade left `sh.helm.release.v1.backstage.v4` in
  `pending-upgrade`.

Fix:

```powershell
kubectl --context gitops-aks -n backstage delete secret sh.helm.release.v1.backstage.v4
```

Then re-run the Terraform apply.

### Reconfigure GitHub OAuth client ID / client secret

Use this when the GitHub OAuth App is recreated, the client secret is rotated, or
Backstage needs to be pointed at a different GitHub OAuth App.

1. Open the GitHub OAuth App in the browser.
   Example used during the final rerun:
   `https://github.com/settings/applications/3703983`
2. Confirm these values:
   - Homepage URL: `https://20.246.0.45`
   - Authorization callback URL:
     `https://20.246.0.45/api/auth/github/handler/frame`
3. Copy the new **Client ID**.
4. Generate a new **Client secret** in the browser and copy it once.
5. Re-apply Backstage with the new credentials (recommended — Terraform stays the
   source of truth, so the value survives future applies):

```powershell
$env:GITHUB_TOKEN = gh auth token
$env:TF_VAR_github_token = $env:GITHUB_TOKEN
$env:TF_VAR_backstage_github_client_id = "<github-oauth-client-id>"
$env:TF_VAR_backstage_github_client_secret = "<new-github-oauth-client-secret>"

terraform -chdir=terraform apply `
  -var build_backstage=true `
  -var gitops_addons_org=https://github.com/zhangchl007 `
  -var gitops_addons_revision=zhangchl007-azure-arc-onboarding `
  -var backstage_image_repository=amllearning02.azurecr.io/backstage `
  -var backstage_image_tag=github-idp-fix2 `
  -target helm_release.backstage
```

> ⚠️ Scope caveat: `-target helm_release.backstage` only touches that Helm release
> and its dependency chain — it does **not** rebuild AKS, VNet/NSG, Fleet, Arc,
> Postgres, ArgoCD, or Key Vault. However, the plan pulls in
> `module.aks.azurerm_kubernetes_cluster.main` as a dependency and may show an
> unrelated in-place drift change (e.g. removing the auto-enabled
> `microsoft_defender` block). Review the plan before confirming: expect
> `1 to change` (Backstage only) or `2 to change` (Backstage + the AKS Defender
> drift). If you do **not** want the AKS change, answer `no` and use the fast
> `kubectl` alternative below instead, then codify the Defender block in the AKS
> module so the drift disappears.

**Fast alternative (hot-swap, no Terraform)** — applies the new secret immediately
but drifts from Terraform/Helm state, so the **next `terraform apply` will revert
it**. Use only for a quick in-demo rotation, and afterwards update
`TF_VAR_backstage_github_client_secret` to keep state consistent:

```powershell
kubectl --context gitops-aks -n backstage set env `
  deploy/backstage-backstagechart GITHUB_CLIENT_SECRET="<new-github-oauth-client-secret>"
kubectl --context gitops-aks -n backstage rollout status deploy/backstage-backstagechart
```

6. Validate:

```powershell
$pod = kubectl --context gitops-aks -n backstage get pods `
  -l app.kubernetes.io/name=backstagechart `
  -o jsonpath='{.items[0].metadata.name}'

kubectl --context gitops-aks -n backstage logs $pod --tail=200
curl.exe -k -I --max-time 20 "https://20.246.0.45/api/auth/github/start?env=development"
```

Expected:

- Logs contain `Configuring auth provider: github`.
- There is no `Missing required config value at 'auth.providers.github.development.clientId'`.
- GitHub auth start endpoint returns `302`.

Cleanup:

```powershell
Remove-Item Env:\TF_VAR_backstage_github_client_id -ErrorAction SilentlyContinue
Remove-Item Env:\TF_VAR_backstage_github_client_secret -ErrorAction SilentlyContinue
Remove-Item Env:\TF_VAR_github_token -ErrorAction SilentlyContinue
Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
```

Notes:

- GitHub OAuth client secrets can only be generated in the browser, not through
  Terraform or GitHub CLI.
- If the secret was pasted into chat, treat it as exposed and rotate it after the
  demo.
- If the OAuth App callback URL does not exactly match the Backstage public URL,
  GitHub sign-in will fail during redirect/callback.
- The client secret is injected as an inline Deployment env var
  (`GITHUB_CLIENT_SECRET`) rendered by the `helm_release.backstage` release —
  there is no separate Kubernetes Secret object to patch. Terraform/Helm owns
  that value, so a `kubectl set env` hot-swap will be reverted on the next
  `terraform apply`. Keep `TF_VAR_backstage_github_client_secret` in sync.

### Expired static TLS secret

Symptom:

```text
CERT_HAS_EXPIRED
```

Cause:

- `kubernetes_secret.tls_secret` read static `tls.crt` / `tls.key` files, and
  the certificate had already expired.

Fix:

- Replace file-based TLS inputs with Terraform-managed `tls_private_key` and
  `tls_self_signed_cert`.
- Restart the Backstage deployment after the secret is updated so the pod loads
  the new certificate.

## ArgoCD / GitOps issues

### ComparisonError: `.status.terminatingReplicas: field not declared in schema`

Symptom (one or many Applications stuck `Unknown` sync status):

```text
ComparisonError: Failed to compare desired state to live state: failed to
calculate diff: error calculating structured merge diff: error building typed
value from live resource: .status.terminatingReplicas: field not declared in
schema (retried 5 times).
```

Cause:

- Kubernetes 1.33+ added the `status.terminatingReplicas` field to Deployment /
  ReplicaSet (graduated further in later releases). This AKS cluster runs
  **v1.35.5**.
- ArgoCD **v2.14.10** ships a bundled client-side OpenAPI schema that predates
  that field. Its default (legacy / structured-merge) diff cannot build a typed
  value from the live resource, so every app containing a Deployment/ReplicaSet
  fails to diff and is reported as `Unknown`.

Fix — enable **Server-Side Diff** (ArgoCD runs a server-side apply dry-run so the
API server, which knows the field, computes the diff):

Live (immediate) fix:

```powershell
kubectl --context gitops-aks -n argocd patch configmap argocd-cmd-params-cm `
  --type merge -p '{\"data\":{\"controller.diff.server.side\":\"true\"}}'

# restart the application controller so it picks up the param
kubectl --context gitops-aks -n argocd rollout restart `
  statefulset/argo-cd-argocd-application-controller
kubectl --context gitops-aks -n argocd rollout status `
  statefulset/argo-cd-argocd-application-controller --timeout=180s
```

Server-Side Diff results are cached, so each affected app must be hard-refreshed
once to recompute (or wait for the next refresh / repo revision / spec change):

```powershell
# refresh a single app
kubectl --context gitops-aks -n argocd annotate application <app-name> `
  argocd.argoproj.io/refresh=hard --overwrite

# or refresh all apps in the namespace
kubectl --context gitops-aks -n argocd get applications.argoproj.io -o name |
  ForEach-Object {
    kubectl --context gitops-aks -n argocd annotate $_ `
      argocd.argoproj.io/refresh=hard --overwrite
  }
```

Durable fix (so a `terraform apply` / ArgoCD self-sync does not revert it) — the
`argocd` block of `module.gitops_bridge_bootstrap` in `terraform/main.tf` passes
the param through the argo-cd Helm chart's `configs.params`, which renders the
`argocd-cmd-params-cm` entry:

```hcl
argocd = {
  namespace     = local.argocd_namespace
  chart_version = var.addons_versions[0].argocd_chart_version
  values = [
    yamlencode({
      configs = {
        params = {
          "controller.diff.server.side" = "true"
        }
      }
    })
  ]
}
```

Validate:

```powershell
kubectl --context gitops-aks -n argocd get applications.argoproj.io `
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers
```

Expected: apps that were `Unknown` return to `Synced` and the `terminatingReplicas`
ComparisonError no longer appears in `.status.conditions`.

Notes:

- Alternative per-app enablement (instead of the global param) is the annotation
  `argocd.argoproj.io/compare-options: ServerSideDiff=true`.
- The older "Structured-Merge Diff" strategy has been discontinued upstream;
  Server-Side Diff is the current, recommended strategy.
- The `addon-gitops-aks-argo-cd` self-management app may still show `OutOfSync` /
  `Missing` for reasons unrelated to this schema bug (e.g. metrics Services and
  HPAs it does not deploy); that is pre-existing and not caused by the diff fix.

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

## Historical note: Entra app registration and 30-day secret

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

### Empty GitHub token or GitHub OAuth runtime values

Symptoms in Backstage pod logs:

```text
Invalid type in config for key 'integrations.github[0].token', got empty-string
Missing required config value at 'auth.providers.github.development.clientId'
Backend startup failed
```

Fix:

- Provide a non-empty GitHub token from `gh auth token`.
- Provide non-empty GitHub OAuth client ID and client secret values.
- Ensure the Helm values are applied through the local chart and Terraform
  `set_sensitive` values.
- Historical note: in the earlier Entra-based recreate, the equivalent failure was
  an empty Microsoft client secret.

Validation:

```powershell
$env:KUBECONFIG = ".\terraform\kubeconfig"
$pod = kubectl get pods -n backstage -l app.kubernetes.io/instance=backstage -o jsonpath='{.items[0].metadata.name}'
kubectl logs $pod -n backstage --tail=200
```

Expected logs:

```text
Found 4 new secrets in config that will be redacted
Configuring auth provider: github
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
- External IP is the current Backstage public IP (final rerun:
  `20.246.0.45`).
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
- The final rerun confirmed the real public-access blocker was the subnet NSG
  `vnet1-aks-nsg-eastus2` missing an inbound allow rule for TCP/443.
- The durable fix was:

```powershell
az network nsg rule create `
  -g aks-gitops `
  --nsg-name vnet1-aks-nsg-eastus2 `
  -n Allow-HTTPS-Inbound `
  --priority 200 `
  --direction Inbound `
  --access Allow `
  --protocol Tcp `
  --source-address-prefixes Internet `
  --destination-port-ranges 443
```

- After the NSG rule was added, external validation returned:
  - `https://20.246.0.45` -> `HTTP 200`
  - `/api/auth/github/start?env=development` -> `HTTP 302`
- The earlier Azure Load Balancer backend-port patch was diagnostic only and was
  not the final root cause or the durable fix.

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
