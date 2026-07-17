# Azure Arc Kubernetes onboarding

This runbook covers the Azure Arc-enabled Kubernetes part of the demo: VM-hosted kind cluster onboarding, Azure Portal resource access, ordinary-user namespace deployment, and troubleshooting.

> Related: use `docs/create-aks-cluster-argocd-fleet-demo.md` for AKS/Fleet/ArgoCD and `docs/backstage-feature-demo.md` for the Backstage GitOps deployment path.

## Relationship to AKS, Azure Arc, and Fleet

Azure Arc should be positioned as the Azure management-plane bridge for
external, hybrid, and multicloud Kubernetes. It should not be positioned as a
replacement for native AKS management.

| Cluster type | Azure operations entry point | GitOps delivery path | What remains native to the cluster platform |
| --- | --- | --- | --- |
| AKS in Azure | AKS resource provider and Azure Kubernetes Fleet Manager | ArgoCD / GitOps in this repository; Azure also supports Flux v2 GitOps | AKS lifecycle, node pools, upgrades, networking, managed identity, and Azure-native integrations |
| AKS enabled by Azure Arc / Azure Local | Arc-enabled AKS resource plus Arc governance | Flux v2 or ArgoCD with explicit ownership boundaries | Local infrastructure lifecycle and supported AKS Arc capabilities |
| External Kubernetes such as TKE, EKS, GKE, OpenShift, on-prem, or VM-hosted kind | Azure Arc-enabled Kubernetes | Control-plane ArgoCD over the reachable cluster API in this demo; Azure Arc also supports Flux v2 GitOps | Provider-specific lifecycle, node pools, upgrades, load balancers, and networking |

Arc-connected clusters appear as Azure Resource Manager resources. This enables
inventory, grouping, tagging, Azure RBAC-mediated cluster-connect access,
Policy, Monitor, Defender, extensions, Marketplace integrations, and GitOps
integration where supported. It does not make every external cluster equivalent
to AKS. AKS is a first-class Azure managed service because it is natively
managed by AKS and related Azure services; external clusters become governable
through Arc, but their lifecycle remains with their native platform.

For the current Arc demo, two VM-hosted kind clusters can be shown side by side:

| VM | Arc cluster | Private kind API |
| --- | --- | --- |
| `arc-kind-vm` | `arc-demo-vm` | `https://10.52.0.4:6443` |
| `arc-kind-vm-2` | `arc-demo-vm-2` | `https://10.52.0.5:6443` |

Human Portal access should use dedicated Microsoft Entra groups whose object IDs
are kept in private deployment configuration. Platform automation and onboarding
use managed identities. The detailed Azure RBAC and Kubernetes RBAC model is
included below for the Arc-managed external kind clusters.

## Multi-cluster permission-control model

Use layered authorization. Do not grant cluster-admin just to make the Azure
Portal or a demo work.

| Layer | What it controls | Recommended practice |
| --- | --- | --- |
| Microsoft Entra groups | Human identity and group membership | Use groups for personas; avoid per-user grants |
| Azure RBAC on the Arc connectedCluster resource | Who can view the Arc resource and request cluster-connect credentials | Grant the minimum Arc Kubernetes roles needed for the persona |
| Arc cluster-connect | Secure access path from Azure to the target API server | Treat it as an access bridge, not an authorization bypass |
| Kubernetes RBAC in the target cluster | Final authority for Kubernetes actions | Use namespace-scoped Roles for ordinary users; reserve ClusterRoleBindings for approved platform personas |
| ArgoCD RBAC and AppProjects | GitOps application visibility and allowed destinations | Restrict by project, cluster, namespace, and allowed resource kinds |
| Backstage Catalog and permissions | Developer discovery and request flow | Use Backstage for self-service requests and read-only visibility, not as a human deployment credential |

Recommended personas:

| Persona | Azure RBAC | Kubernetes RBAC | Notes |
| --- | --- | --- | --- |
| Platform administrators / `k8sadmin` | Administrative rights on platform resources | Cluster-admin on approved platform targets | Small, audited group only |
| External-cluster operators | Arc cluster user/viewer/writer roles as required | Scoped operational roles per cluster | Useful for TKE or on-prem operations teams |
| Namespace application operators | Arc access only where Portal operations are approved | Namespace Role/RoleBinding | Write access should stay inside the namespace |
| Read-only observers | Arc viewer roles | `view` or narrower custom roles | Suitable for inventory and troubleshooting |
| Backstage users | Backstage sign-in group | No direct deployment credential | Requests flow through PR and ArgoCD |

## Arc Portal access model: SSO group plus managed identities

Use separate identities for human Portal access and automation:

| Identity | Used by | Responsibilities |
| --- | --- | --- |
| Dedicated Microsoft Entra Portal group | Human users signing in to Azure Portal | Browse Arc-enabled Kubernetes resources, deploy or edit namespace-scoped demo resources, and use Arc cluster-connect through the Portal |
| VM system-assigned managed identity | Each VM-hosted kind cluster | Run `az connectedk8s connect`, enable Arc features, and manage the connectedCluster lifecycle from the VM |
| Platform managed identity | Control-plane automation | Own platform automation such as Arc/Fleet role assignments, GitOps/bootstrap integration, and ArgoCD registration workflows |

Required Azure RBAC on each Arc connected cluster resource:

```powershell
$groupId = "<private-entra-group-object-id>"

foreach ($cluster in @("arc-demo-vm", "arc-demo-vm-2")) {
  $scope = az connectedk8s show `
    -g <resource-group> `
    -n $cluster `
    --query id `
    -o tsv

  foreach ($role in @(
    "Azure Arc Enabled Kubernetes Cluster User Role",
    "Azure Arc Kubernetes Viewer",
    "Azure Arc Kubernetes Writer"
  )) {
    az role assignment create `
      --assignee-object-id $groupId `
      --assignee-principal-type Group `
      --role $role `
      --scope $scope
  }
}
```

Required Kubernetes RBAC inside each VM-hosted kind cluster is the
`portal-demo-editor` namespace Role in
`gitops/apps/portal-namespace-demo/portal-namespace-demo.yaml`, bound to the
dedicated Portal group through a private overlay. The secure binding template
and validation steps are in [Repair namespace RBAC without granting cluster
admin](#4-repair-namespace-rbac-without-granting-cluster-admin).

Do not create a `ClusterRoleBinding` or assign **Azure Arc Kubernetes Cluster
Admin** to this ordinary-user group. The Azure Portal access model is
namespace-scoped: the group obtains a cluster-connect credential, then the
`portal-demo-editor` `RoleBinding` limits its Kubernetes actions to that
namespace.

Azure Portal does not directly call the VM private kind API endpoint. The Portal
Kubernetes resources blade uses Azure Arc cluster-connect and in-cluster
`kube-aad-proxy`:

```text
Azure Portal -> Azure Arc cloud relay -> clusterconnect-agent / kube-aad-proxy -> kind API
```

ArgoCD continues to use the private VNet path and is expected to be faster and
more stable for multi-cluster delivery:

```text
ArgoCD on gitops-aks -> https://10.52.x.x:6443
```

## Azure Arc GitOps best practices

Azure Arc and AKS support Azure-managed GitOps with Flux v2 through Kubernetes
configuration and cluster extensions. Flux is a good fit when the customer wants
Azure-native GitOps configuration directly attached to each cluster.

This repository intentionally uses ArgoCD as the single continuous reconciler
because the demo centers on ArgoCD application health, AppProjects, app-of-apps
topology, Backstage-generated pull requests, and centralized multi-cluster
delivery from `gitops-aks`.

Best practices:

- Keep all Kubernetes desired state in Git.
- Use pull requests and branch protection for production changes.
- Keep secrets out of Git; reference bootstrap or external secrets
  declaratively.
- Do not let Flux and ArgoCD reconcile the same resources. If a customer uses
  both, partition ownership by namespace, repository path, resource type, or
  cluster.
- Use Azure Policy, Defender, Monitor, and Arc extensions for governance and
  visibility, not as substitutes for Kubernetes RBAC or GitOps ownership.
- Use ArgoCD AppProjects or equivalent policy boundaries to restrict cluster,
  namespace, and resource destinations.

## Arc kind onboarding quick procedure

Use this when the demo environment needs to create or refresh the VM-hosted kind
clusters behind the Arc view.

1. Create a local ignored Terraform variable file such as
   `terraform/arc-demo.auto.tfvars`:

   ```hcl
   arc_kind_vms = {
     arc-kind-vm = {
       cluster_name   = "arc-demo-vm"
       size           = "Standard_D4as_v6"
       admin_username = "azureuser"
       api_port       = 6443
     }
     arc-kind-vm-2 = {
       cluster_name   = "arc-demo-vm-2"
       size           = "Standard_D4as_v6"
       admin_username = "azureuser"
       api_port       = 6443
     }
   }
   ```

   The reusable `terraform/modules/arc-kind-vm` module creates every map entry,
   including its NIC, NSG, VNet-only API rule, Standard outbound public IP,
   system-assigned VM identity, and Arc onboarding role assignments. The Arc
   onboarding output is derived from this map, so no duplicate
   `arc_external_clusters` entry is needed for VM-hosted kind clusters.

2. Apply Terraform with the same variables used for the customer demo:

   ```powershell
   terraform -chdir=terraform apply `
     -var build_backstage=true `
     -var location=eastus2 `
     -var postgres_location=westus3 `
     -var gitops_addons_org=https://github.com/zhangchl007 `
     -var gitops_addons_revision=zhangchl007-arc-multi-cluster-access
   ```

3. Onboard each VM-hosted kind cluster to Arc and ArgoCD:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass `
     -File .\scripts\arc-kind-vm-onboard.ps1 `
     -ClusterName arc-demo-vm `
     -ControlPlaneContext gitops-aks `
     -ResourceGroup aks-gitops `
     -VmName arc-kind-vm

   powershell.exe -ExecutionPolicy Bypass `
     -File .\scripts\arc-kind-vm-onboard.ps1 `
     -ClusterName arc-demo-vm-2 `
     -ControlPlaneContext gitops-aks `
     -ResourceGroup aks-gitops `
     -VmName arc-kind-vm-2
   ```

4. Confirm both VM NICs are in the AKS VNet and expose only the private kind API
   from the VNet on TCP `6443`:

   ```powershell
   az network nic show `
     -g aks-gitops `
     -n arc-kind-vm-nic `
     --query "{privateIp:ipConfigurations[0].privateIPAddress,subnet:ipConfigurations[0].subnet.id}" `
     -o json

   az network nic show `
     -g aks-gitops `
     -n arc-kind-vm-2-nic `
     --query "{privateIp:ipConfigurations[0].privateIPAddress,subnet:ipConfigurations[0].subnet.id}" `
     -o json
   ```

The onboarding script reads `arc_kind_vms[$VmName].private_ip` when Terraform
outputs are available, falls back to legacy `arc_kind_vm`, and accepts
`-PrivateIp` for manually provisioned or recovered environments.

## Azure Portal namespace deployment quick procedure

Use Azure Portal / Arc as the low-friction ordinary-user entry point for simple
namespace-scoped resources. The safe sample manifest is:

```text
gitops/apps/portal-namespace-demo/portal-namespace-demo.yaml
```

It includes `Namespace`, namespace-scoped `Role` and `RoleBinding`,
`Deployment`, `StatefulSet`, `ConfigMap`, placeholder-only `Secret`, and
`Service`.

Demo flow:

1. In Azure Portal, open `arc-demo-vm` or `arc-demo-vm-2`.
2. Open the Kubernetes resources view.
3. Use the YAML editor/import flow to apply
   `gitops/apps/portal-namespace-demo/portal-namespace-demo.yaml`.
4. Confirm namespace `portal-demo` and its sample workloads appear.
5. Edit a safe field such as the `APP_MESSAGE` value in the `ConfigMap` or the
   Deployment replica count.

### Portal browser compatibility and visibility boundary

The Azure Portal Kubernetes resources blade sends cluster-scoped `list
namespaces` and resource-list requests before rendering its namespace selector.
Kubernetes does not filter a namespace list. To render the Portal blade,
`portal_browser_compatible = true` grants the configured subject the
cluster-wide Kubernetes `view` ClusterRole.

This enables read-only browsing across namespaces, while the namespace-local
`portal-demo-editor` Role continues to control writes. A successful deployment
has the following result through a fresh Arc cluster-connect proxy:

```text
portal-demo pods:          yes
default pods:              yes (read-only)
namespaces:                yes (names visible)
create in portal-demo:     yes
create in default:         no
```

Use this mode only for the customer demo. For production, use Backstage,
Backstage and ArgoCD for workload operations and reserve Portal browsing for
appropriately trusted users.

The `arc_kind_vms` module standardizes the required private configuration. Keep
the tenant-specific subjects only in an ignored environment tfvars file:

```hcl
arc_kind_portal_access = {
  arc-kind-vm = {
    namespace                 = "portal-demo"
    portal_browser_compatible = true
    subjects = [{
      kubernetes_kind      = "Group"
      kubernetes_name      = "<private-entra-group-object-id>"
      azure_principal_id   = "<private-entra-group-object-id>"
      azure_principal_type = "Group"
    }]
  }
}

# Change deliberately to rerun the idempotent VM kind, Arc, and RBAC bootstrap.
arc_kind_bootstrap_revision = "1"
```

The module installs or repairs kind and Arc cluster-connect, applies the
namespace-local `portal-demo-editor` Role and RoleBinding, and assigns the
required Azure Arc roles to each configured subject. With
`portal_browser_compatible = true`, it additionally creates the read-only
`portal-demo-browser-read` ClusterRoleBinding required by the Portal blade.


## Demo: show Arc-managed external kind clusters

Use this short side-by-side view when positioning AKS Fleet and Azure Arc in the
same customer conversation:

```powershell
az connectedk8s list `
  -g aks-gitops `
  --query "[?name=='arc-demo-vm' || name=='arc-demo-vm-2'].{name:name,provisioningState:provisioningState,connectivityStatus:connectivityStatus,kubernetesVersion:kubernetesVersion,totalNodeCount:totalNodeCount}" `
  -o table

kubectl --context gitops-aks-admin -n argocd get application `
  platform-demo-kind-arc-demo-vm,platform-demo-kind-arc-demo-vm-2 `
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEST:.spec.destination.name
```

Expected:

```text
Name           ProvisioningState    ConnectivityStatus    KubernetesVersion    TotalNodeCount
-------------  -------------------  --------------------  -------------------  ----------------
arc-demo-vm    Succeeded            Connected             1.31.0               1
arc-demo-vm-2  Succeeded            Connected             1.31.0               1

NAME                              SYNC     HEALTH    DEST
platform-demo-kind-arc-demo-vm    Synced   Healthy   arc-demo-vm
platform-demo-kind-arc-demo-vm-2  Synced   Healthy   arc-demo-vm-2
```

Talking point:

> Fleet gives the AKS estate a unified management layer. Azure Arc gives external
> clusters, such as VM-hosted kind, a unified Azure resource view. ArgoCD is the
> common GitOps control plane that can target both. The default customer demo
> keeps one curated `platform-demo-kind-*` workload per Arc cluster; the older
> `arc-baseline-*` sample workload is opt-in only.

## Troubleshooting: Azure Portal Arc resource browser shows `Failed to fetch`

Symptom:

```text
Unable to reach the api server or api server is too busy to respond.
{"message":"Failed to fetch","isError":true}
```

This message is ambiguous. It can mean that the Arc relay is unavailable, but
it can also be the Portal's generic rendering of an authenticated Kubernetes
RBAC denial. Do not recreate the kind cluster or reconnect it to Arc until the
checks below identify which layer is failing.

The Portal Kubernetes resources blade uses Arc cluster-connect and in-cluster
`kube-aad-proxy`; it does **not** directly call the VM private kind API:

```text
Azure Portal -> Arc cluster-connect -> kube-aad-proxy -> Kubernetes RBAC -> kind API
```

The approved ArgoCD delivery path is:

```text
gitops-aks -> private VNet -> https://10.52.x.x:6443 -> kind API
```

### 1. Confirm the private kind APIs are healthy

Run this from `gitops-aks`, which has VNet access to both VM-hosted kind APIs:

```powershell
$context = "gitops-aks-admin"
$namespace = "argocd"
$pod = "arc-private-api-check"

kubectl --context $context -n $namespace run $pod `
  --image=curlimages/curl:8.11.1 `
  --restart=Never `
  --command -- sleep 120

kubectl --context $context -n $namespace wait `
  --for=condition=Ready pod/$pod `
  --timeout=90s

foreach ($endpoint in @(
  "https://10.52.0.4:6443/version",
  "https://10.52.0.5:6443/version"
)) {
  kubectl --context $context -n $namespace exec $pod -- `
    curl -k -sS --connect-timeout 5 --max-time 15 `
      -w "`nHTTP %{http_code}`n" $endpoint
}

kubectl --context $context -n $namespace delete pod/$pod --ignore-not-found
```

Expected: each endpoint returns Kubernetes version JSON and `HTTP 200`. If both
do, the kind control planes, VM network, and TCP `6443` NSG path are healthy;
continue with the Arc relay and RBAC checks instead of changing the VMs.

### 2. Check the Arc resource and cluster-connect agents

Check both connected-cluster resources:

```powershell
az connectedk8s list `
  -g <resource-group> `
  --query "[?name=='arc-demo-vm' || name=='arc-demo-vm-2'].{name:name,provisioningState:provisioningState,connectivityStatus:connectivityStatus,agentVersion:agentVersion}" `
  -o table
```

Expected: both are `Succeeded` and `Connected`. A connected resource does not
prove that the current Portal user has Kubernetes access; it only proves that
the Arc agent control channel is online.

Inspect the agents from each VM. Use POSIX shell syntax because VM Run Command
uses `/bin/sh`; `set -o pipefail` is not portable there and will prevent the
diagnostic script from running.

```powershell
$script = @'
set -eu
export KUBECONFIG=/root/.kube/config
echo "context=$(kubectl config current-context)"
kubectl get nodes -o wide
kubectl -n azure-arc get pods -o wide
kubectl -n azure-arc get deploy
kubectl -n azure-arc get events --sort-by=.lastTimestamp | tail -40
'@

foreach ($vm in @("arc-kind-vm", "arc-kind-vm-2")) {
  az vm run-command invoke `
    -g <resource-group> `
    -n $vm `
    --command-id RunShellScript `
    --scripts $script `
    --query "value[0].message" `
    -o tsv
}
```

If the `azure-arc` namespace is absent, its pods are not running, or the
connected-cluster state is not `Connected`, rerun
`scripts/arc-kind-vm-onboard.ps1` only after confirming the VM's managed
identity still has the required Arc roles. The script reconnects an existing
connected-cluster resource when the Arc agents are missing.

### 3. Test the same cluster-connect path outside the Portal

`az connectedk8s proxy` is the best discriminator because it uses the same Arc
cluster-connect relay as the Portal. Run only one proxy at a time: the Azure CLI
uses an internal local relay port and concurrent proxies can fail with a port
already in use error even when different `--port` values are supplied.

```powershell
$kubeconfig = Join-Path $env:TEMP "arc-demo-vm-proxy.yaml"

az connectedk8s proxy `
  -g <resource-group> `
  -n arc-demo-vm `
  --port 47101 `
  --file $kubeconfig

# In a second terminal after the proxy writes the kubeconfig:
kubectl --kubeconfig $kubeconfig get pods -n portal-demo
kubectl --kubeconfig $kubeconfig auth can-i list pods -n portal-demo
kubectl --kubeconfig $kubeconfig auth can-i list pods -n default
kubectl --kubeconfig $kubeconfig auth can-i list namespaces
```

Interpret the result:

| Result | Meaning | Next action |
| --- | --- | --- |
| Proxy cannot start or API requests time out | Arc cluster-connect/agent path is failing | Return to step 2 and inspect Arc agents, VM egress, and Arc resource state |
| `HTTP 404` at `https://127.0.0.1:<port>/version` | Expected: the proxy requires its generated `/proxies/<id>` path | Use the generated kubeconfig rather than calling the listener root |
| `Forbidden` for `nodes` or `namespaces` | Expected when `portal_browser_compatible` is `false` | Test `portal-demo`, not cluster-scoped resources |
| `Forbidden` in `portal-demo` | Arc relay works; Kubernetes RBAC is missing or does not match the authenticated identity | Apply the namespace RoleBinding described in step 4 |
| Lists namespaces and pods across clusters; writes are allowed only in `portal-demo` | Correct Portal-browser-compatible result | Refresh the Portal page and use the `portal-demo` namespace for changes |

### 4. Repair namespace RBAC without granting cluster admin

The public sample manifest intentionally contains a placeholder group name:

```yaml
subjects:
  - kind: Group
    name: portal-demo-users
```

Do not commit a tenant-specific object ID to replace that placeholder. Generate
the private overlay or apply the binding from a secure automation location. The
binding must reference the exact identity emitted by `kube-aad-proxy`:

- Use `kind: Group` with the Entra group object ID only when the proxy token
  includes that group claim.
- Use `kind: User` with the exact user principal name shown in the proxy
  `Forbidden` response for a short-lived single-user demo.

The following secure template gives only the `portal-demo-editor` Role already
defined by the sample manifest; it does not grant cluster-wide access:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: portal-demo-private-access
  namespace: portal-demo
subjects:
  - kind: Group
    name: "<entra-group-object-id>"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: portal-demo-editor
```

### 5. Control Portal browser visibility

With `portal_browser_compatible = true`, the following checks intentionally
return `yes` because the Portal blade requires the `view` ClusterRole:

```powershell
kubectl --kubeconfig $kubeconfig auth can-i list namespaces
kubectl --kubeconfig $kubeconfig auth can-i list pods -n default
```

The module creates a dedicated `portal-demo-browser-read` binding to `view`.
Do not add the Portal user to a platform or deployer group: those groups may
also grant `admin` or deployment rights in application namespaces.

1. Keep only the dedicated `portal-demo-browser-read` binding for read access.
2. Keep the namespace-local `portal-demo-editor` RoleBinding for write access.
3. Do not create a cluster-admin binding or bind the Portal user to an
   application deployer group.
4. Close existing `az connectedk8s proxy` processes, sign out of Azure Portal,
   then sign in again before retesting. Entra group claims are minted into
   access tokens, so an existing Portal or proxy token retains its old group
   membership until refreshed.

The expected Portal-browser-compatible result on **each** Arc cluster is:

```text
portal-demo pods: yes
default pods:     yes (read-only)
namespaces:       yes
create portal-demo: yes
create default:     no
```

If a user was added to the Entra group while troubleshooting, refresh their
Azure authentication before retesting:

```powershell
az logout --username <user-principal-name>
az login
```

Then start a new `az connectedk8s proxy` session. Group claims are minted in the
token and an existing proxy session can continue to use a stale token.

The Portal user or group must have both:

- Azure RBAC on each Arc connected cluster resource.
- Kubernetes RBAC inside each target kind cluster.

Keep the long-term model group-based and inject tenant-specific groups through
private deployment configuration. A direct user RoleBinding is only appropriate
for a time-boxed demo diagnostic.
