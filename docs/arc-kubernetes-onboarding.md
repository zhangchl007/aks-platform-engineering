# Azure Arc Kubernetes onboarding

This runbook covers the Azure Arc-enabled Kubernetes part of the demo: VM-hosted kind cluster onboarding, Azure Portal resource access, ordinary-user namespace deployment, and troubleshooting.

> Related: use `docs/create-aks-cluster-argocd-fleet-demo.md` for AKS/Fleet/ArgoCD and `docs/devtron-poc-foundation.md` for the Devtron deployment portal POC.

## Relationship to Azure Arc external clusters

This demo is for AKS workload clusters. AKS clusters join Azure Kubernetes Fleet
Manager, while external / non-AKS clusters such as the VM-hosted kind clusters
use Azure Arc-enabled Kubernetes.

| Cluster type | Unified view | Application delivery path | Ordinary-user portal path |
| --- | --- | --- | --- |
| AKS control-plane and AKS workload clusters | Azure Kubernetes Fleet Manager | ArgoCD / GitOps | AKS resource view and AKS RBAC |
| VM-hosted kind / external Kubernetes | Azure Arc-enabled Kubernetes | Control-plane ArgoCD over private kind API | Azure Portal Arc Kubernetes resources through cluster-connect |

For the current Arc demo, two VM-hosted kind clusters can be shown side by side:

| VM | Arc cluster | Private kind API |
| --- | --- | --- |
| `arc-kind-vm` | `arc-demo-vm` | `https://10.52.0.4:6443` |
| `arc-kind-vm-2` | `arc-demo-vm-2` | `https://10.52.0.10:6443` |

Human Portal access should use the Microsoft Entra group
`akspe-arc-portal-users`. Platform automation and onboarding use managed
identities. The detailed Azure RBAC and Kubernetes RBAC model is included below
for the Arc-managed external kind clusters.

## Arc Portal access model: SSO group plus managed identities

Use separate identities for human Portal access and automation:

| Identity | Used by | Responsibilities |
| --- | --- | --- |
| Microsoft Entra group `akspe-arc-portal-users` | Human users signing in to Azure Portal | Browse Arc-enabled Kubernetes resources, deploy or edit namespace-scoped demo resources, and use Arc cluster-connect through the Portal |
| VM system-assigned managed identity | Each VM-hosted kind cluster | Run `az connectedk8s connect`, enable Arc features, and manage the connectedCluster lifecycle from the VM |
| Platform managed identity `akspe` | Control-plane automation | Own platform automation such as Arc/Fleet role assignments, GitOps/bootstrap integration, and ArgoCD registration workflows |

For the current demo, the Portal group object ID is:

```text
akspe-arc-portal-users = 920dd21d-dc35-4eb2-8574-94a4ca0c86fb
```

Required Azure RBAC on each Arc connected cluster resource:

```powershell
$groupId = "920dd21d-dc35-4eb2-8574-94a4ca0c86fb"

foreach ($cluster in @("arc-demo-vm", "arc-demo-vm-2")) {
  $scope = az connectedk8s show -g aks-gitops -n $cluster --query id -o tsv

  foreach ($role in @(
    "Azure Arc Enabled Kubernetes Cluster User Role",
    "Azure Arc Kubernetes Viewer",
    "Azure Arc Kubernetes Writer",
    "Azure Arc Kubernetes Cluster Admin"
  )) {
    az role assignment create `
      --assignee-object-id $groupId `
      --assignee-principal-type Group `
      --role $role `
      --scope $scope
  }
}
```

Required Kubernetes RBAC inside each VM-hosted kind cluster:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: akspe-arc-portal-users-cluster-admin
  labels:
    app.kubernetes.io/managed-by: akspe-arc-demo
    access-model: azure-portal-arc
subjects:
  - kind: Group
    name: "920dd21d-dc35-4eb2-8574-94a4ca0c86fb"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
---
apiVersion: v1
kind: Namespace
metadata:
  name: portal-demo
  labels:
    access-model: azure-portal-arc
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: akspe-arc-portal-users-namespace-admin
  namespace: portal-demo
  labels:
    app.kubernetes.io/managed-by: akspe-arc-demo
    access-model: azure-portal-arc
subjects:
  - kind: Group
    name: "920dd21d-dc35-4eb2-8574-94a4ca0c86fb"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
```

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

## Arc kind onboarding quick procedure

Use this when the demo environment needs to create or refresh the VM-hosted kind
clusters behind the Arc view.

1. Create a local ignored Terraform variable file such as
   `terraform/arc-demo.auto.tfvars`:

   ```hcl
   enable_arc_kind_vm = true
   arc_kind_vm_size   = "Standard_D4as_v6"

   additional_arc_kind_vms = {
     arc-kind-vm-2 = {
       cluster_name   = "arc-demo-vm-2"
       size           = "Standard_D4as_v6"
       admin_username = "azureuser"
       api_port       = 6443
     }
   }

   arc_external_clusters = {
     arc-demo-vm   = ""
     arc-demo-vm-2 = ""
   }
   ```

2. Apply Terraform with the same variables used for the customer demo:

   ```powershell
   terraform -chdir=terraform apply `
     -var build_backstage=true `
     -var location=eastus2 `
     -var postgres_location=westus3 `
     -var gitops_addons_org=https://github.com/zhangchl007 `
     -var gitops_addons_revision=zhangchl007-azure-arc-onboarding
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


## Demo: show Arc-managed external kind clusters

Use this short side-by-side view when positioning AKS Fleet and Azure Arc in the
same customer conversation:

```powershell
az connectedk8s list `
  -g aks-gitops `
  --query "[?name=='arc-demo-vm' || name=='arc-demo-vm-2'].{name:name,provisioningState:provisioningState,connectivityStatus:connectivityStatus,kubernetesVersion:kubernetesVersion,totalNodeCount:totalNodeCount}" `
  -o table

kubectl --context gitops-aks -n argocd get application `
  arc-baseline-arc-demo-vm,arc-baseline-arc-demo-vm-2 `
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEST:.spec.destination.name
```

Expected:

```text
Name           ProvisioningState    ConnectivityStatus    KubernetesVersion    TotalNodeCount
-------------  -------------------  --------------------  -------------------  ----------------
arc-demo-vm    Succeeded            Connected             1.31.0               1
arc-demo-vm-2  Succeeded            Connected             1.31.0               1

NAME                         SYNC     HEALTH    DEST
arc-baseline-arc-demo-vm     Synced   Healthy   arc-demo-vm
arc-baseline-arc-demo-vm-2   Synced   Healthy   arc-demo-vm-2
```

Talking point:

> Fleet gives the AKS estate a unified management layer. Azure Arc gives external
> clusters, such as VM-hosted kind, a unified Azure resource view. ArgoCD is the
> common GitOps control plane that can target both.

## Troubleshooting: Azure Portal Arc resource browser shows `Failed to fetch`

Symptom:

```text
Unable to reach the api server or api server is too busy to respond.
{"message":"Failed to fetch","isError":true}
```

This usually does not mean the kind cluster is down. The Portal Kubernetes
resources blade uses Arc cluster-connect and in-cluster `kube-aad-proxy`, not
direct browser access to the VM private kind API endpoint.

Check the Arc resource and agents:

```powershell
az connectedk8s list `
  -g aks-gitops `
  --query "[?name=='arc-demo-vm' || name=='arc-demo-vm-2'].{name:name,provisioningState:provisioningState,connectivityStatus:connectivityStatus,agentVersion:agentVersion}" `
  -o table

$script = @'
export KUBECONFIG=/root/.kube/config
kubectl -n azure-arc get pods
kubectl -n azure-arc get deploy
'@

az vm run-command invoke `
  -g aks-gitops `
  -n arc-kind-vm `
  --command-id RunShellScript `
  --scripts $script `
  --query "value[0].message" `
  -o tsv
```

Check the CLI cluster-connect path:

```powershell
az connectedk8s proxy `
  -g aks-gitops `
  -n arc-demo-vm-2 `
  --port 47022 `
  --kube-context arc-proxy-arc-demo-vm-2

kubectl --context arc-proxy-arc-demo-vm-2 get ns
```

If CLI proxy works but Portal still fails, sign out and back in to refresh the
Entra group and Azure role claims. The user or group must have both:

- Azure RBAC on each Arc connected cluster resource.
- Kubernetes RBAC inside each target kind cluster.

Use `akspe-arc-portal-users` for human access and managed identities for
automation. Avoid using a single shared human account as the long-term access
model.
