# Demo: Create a new AKS workload cluster with ArgoCD and Fleet Manager

This demo shows how `aks-platform-engineering` can create a new AKS workload
cluster from the management cluster, bring it under GitOps control, and join it to
Azure Kubernetes Fleet Manager.

## What the customer will see

1. Platform team commits a new workload-cluster definition to Git.
2. Control-plane ArgoCD detects the change and syncs CAPZ resources.
3. Cluster API Provider Azure (CAPZ) creates the AKS workload cluster.
4. The workload cluster joins Azure Kubernetes Fleet Manager.
5. ArgoCD bootstraps platform add-ons / workload apps for the new cluster.
6. The operator verifies the new AKS cluster, ArgoCD apps, and Fleet membership.

```mermaid
flowchart LR
  Git["Git repo<br/>cluster definition"] --> ArgoHub["Control-plane ArgoCD"]
  ArgoHub --> CAPZ["CAPZ + ASO<br/>on management AKS"]
  CAPZ --> AKS["New AKS workload cluster"]
  CAPZ --> Fleet["Azure Kubernetes<br/>Fleet Manager"]
  AKS --> WorkloadArgo["Workload-cluster ArgoCD<br/>(optional / bootstrapped)"]
  WorkloadArgo --> Apps["Platform add-ons<br/>and team apps"]
```

## Concepts

### Related runbooks

- `docs/arc-kubernetes-onboarding.md` covers Azure Arc-enabled Kubernetes, VM-hosted kind onboarding, Portal access, and Arc troubleshooting.
- Backstage is the supported self-service entry point: it creates reviewable
  GitOps changes, which ArgoCD reconciles after approval.


### Control-plane ArgoCD

The control-plane AKS cluster runs ArgoCD. It owns the platform control loop:

- syncs `gitops/bootstrap/control-plane/addons`,
- installs CAPZ / Cluster API components,
- syncs `gitops/clusters/<provider>`,
- creates workload AKS clusters through Kubernetes custom resources.

### CAPZ-managed AKS workload cluster

The CAPZ sample in this repository uses:

- `gitops/clusters/clusters-argo-applicationset.yaml` as the cluster provisioning
  entry point,
- `gitops/clusters/capz/aks-appset.yaml` to render an AKS cluster Application
  when cluster provisioning is enabled,
- `gitops/clusters/capz/charts/azure-managed-cluster` as the Helm chart that emits
  CAPZ resources such as `Cluster`, `AzureManagedControlPlane`,
  `AzureManagedCluster`, and managed agent pools.

### Fleet Manager membership

The CAPZ chart has a Fleet member block, but the demo keeps it disabled because
the installed CAPZ release uses an older Fleet member API:

```yaml
controlplane:
  fleetsMember:
    enabled: false
    name: <cluster-name>-fleet-member
    group: <fleet-group>
    managerName: gitops-fleet
    managerResourceGroup: aks-gitops
```

The workload cluster is joined to Fleet Manager after AKS is ready with
`az fleet member create`.

### ArgoCD registration options

There are two useful GitOps patterns:

| Pattern | What it means | When to use |
| --- | --- | --- |
| Control-plane ArgoCD provisions the cluster | ArgoCD syncs CAPZ resources that create AKS | Always for this demo |
| Workload cluster has its own ArgoCD | CAPZ HelmChartProxy installs ArgoCD into the new cluster | Team autonomy / app GitOps per cluster |
| Central ArgoCD also targets workload cluster | Create an ArgoCD cluster Secret in the control-plane ArgoCD | Single central view of all target clusters |

This repository already has the first two patterns. A central registration script can
be added for customers who want one ArgoCD instance to target all clusters.

## Prerequisites

- Terraform bootstrap has already created the management AKS cluster.
- ArgoCD is running in the `argocd` namespace of the management cluster.
- CAPZ / Cluster API operator add-ons are healthy.
- Fleet Manager exists:

```powershell
az fleet show -g aks-gitops -n gitops-fleet -o table
```

- The Git branch used by ArgoCD is pushed and matches
  `addons_repo_revision` in the management cluster Secret.

Check ArgoCD:

```powershell
kubectl --context gitops-aks-admin -n argocd get pods
kubectl --context gitops-aks-admin -n argocd get applications
```

For the live POC, ArgoCD is exposed at:

```text
https://172.179.107.194
```

ArgoCD uses Microsoft Entra SSO through the shared app registration. The private `k8sadmin` group
object ID maps to ArgoCD `role:admin` and is the platform administrator group
for AKS, kind clusters, and Backstage. The private
`akspe-aks-cluster-deployers` group object ID has Kubernetes `view` on every
registered AKS target and can request approved GitOps delivery to
`gitops-aks/group2-aks-apps`; it is not the ArgoCD administrator group. The
private
`akspe-kind-cluster-deployers` group object ID is intentionally not granted
ArgoCD admin access and can request approved GitOps delivery only to
`arc-demo-vm/group1-apps` and
`arc-demo-vm-2/group1-apps`.

Keep the private `k8sadmin` object ID as the AKS managed Entra admin group. For
Backstage sign-in, use one common Entra group, `akspe-backstage-users`, instead
of adding each access group to Backstage one by one. The AKS and kind deployer
groups, plus `k8sadmin`, are members of that common Backstage group:

```hcl
rbac_aad_admin_group_object_ids = ["<private-k8sadmin-group-object-id>"]

backstage_allowed_group_object_ids = [
  "<private-akspe-backstage-users-group-object-id>"
]
```

ArgoCD also owns the cross-tool access baseline for registered targets:

| GitOps asset | Purpose |
| --- | --- |
| `gitops/apps/platform-access/manifests/platform-access-policy-configmap.yaml` | Non-secret policy for AKS/kind target lists, approved deployment namespaces, and Backstage-visible cluster metadata |
| `gitops/apps/platform-access/manifests/backstage-sso-convergence-job.yaml` | ArgoCD hook that patches Backstage to use only the common `akspe-backstage-users` group ID from `backstage/platform-backstage-sso` |
| `gitops/apps/platform-access/manifests/platform-target-baseline-appset.yaml` | Applies per-target baseline RBAC to every registered AKS/kind cluster selected by ArgoCD cluster Secret metadata |
| `gitops/apps/platform-access/manifests/platform-demo-apps-appset.yaml` | Creates ArgoCD Applications for the approved AKS/kind demo namespaces so workloads are reconciled by ArgoCD, not manually |
| `gitops/apps/platform-target-baseline` | Helm chart that grants `k8sadmin` cluster-admin, Backstage read-only access, and AKS deployer view access on each target type |
| `gitops/apps/platform-demo` | Sample ArgoCD-managed workloads deployed to `group1-apps` on kind targets and `group2-aks-apps` on AKS targets |

When registering a new AKS target, pass the private AKS deployer group object ID
to ensure the target baseline grants the group read-only `view` access:

```powershell
.\scripts\register-aks-workload-cluster.ps1 `
  -ClusterName <new-aks-name> `
  -ResourceGroupName <new-aks-resource-group> `
  -AksDeployerGroupObjectId "<private-aks-deployer-group-object-id>"
```

New AKS targets are not deployment targets by default. They become visible to
`k8sadmin` and AKS deployers after access convergence, but deployment remains
disabled unless a reviewed GitOps change adds the exact cluster/namespace to the
approved delivery policy and AppProject. For a deliberately approved demo target,
register with `-EnableDeployment -DeployNamespace <namespace>` and update the
`aks-team-delivery` destination allow-list in Git.

When registering a new AKS cluster as a central ArgoCD target, use
`scripts/register-aks-workload-cluster.ps1`. The script labels the cluster Secret
as an AKS platform-access target. Re-run
`scripts/configure-k8sadmin-access.ps1` afterward so the private `k8sadmin`
group object ID is annotated onto the new cluster Secret. This gives `k8sadmin`
cluster-admin on the new AKS target and lets `akspe-aks-cluster-deployers` view
AKS targets. Deployment write access is still granted only for namespaces
explicitly listed in the platform access policy and the matching AppProject,
starting with `gitops-aks/group2-aks-apps`.

The same script creates/resolves the common `akspe-backstage-users` group, adds
the platform access groups under it, writes its object ID to
`backstage/platform-backstage-sso`, and lets ArgoCD's `platform-access`
application reconcile Backstage `BACKSTAGE_ALLOWED_GROUP_IDS`. This keeps
Backstage SSO centralized instead of maintaining a growing comma-separated list
on the deployment.

Backstage exposes separate delivery templates for ordinary users. Create and
update paths remain target-specific, while the cleanup path is shared because it
removes an already generated delivery and its Catalog descriptor:

| Template | Visible to | Destination / action |
| --- | --- | --- |
| `deploy-aks-application` | `k8sadmin`, `akspe-aks-cluster-deployers` | Creates a reviewed PR for `gitops-aks/group2-aks-apps` through `aks-team-delivery` |
| `deploy-kind-application` | `k8sadmin`, `akspe-kind-cluster-deployers` | Creates a reviewed PR for `arc-demo-vm/group1-apps` or `arc-demo-vm-2/group1-apps` through `kind-team-delivery` |
| `update-aks-application` | `k8sadmin`, `akspe-aks-cluster-deployers` | Updates an existing generated AKS delivery Application through `aks-team-delivery` |
| `update-kind-application` | `k8sadmin`, `akspe-kind-cluster-deployers` | Updates an existing generated Arc/kind delivery ApplicationSet through `kind-team-delivery` |
There is no Backstage delete template. Cleanup is a manual platform PR that
removes the generated GitOps delivery directory, generated Catalog descriptor,
and Catalog index target together.

Backstage delivery is Git-first and asynchronous. A merged Backstage PR means
the desired state is on the watched branch; it does not mean the target cluster
has already finished deployment. For Arc/kind delivery, wait for
`backstage-delivery-apps`, the generated ApplicationSet, its child Applications
for `arc-demo-vm` and `arc-demo-vm-2`, and the `group1-apps` workloads to become
`Synced` / `Healthy` before calling the deployment complete.

For faster demos, run the refresh helper after the PR merge instead of waiting
for ArgoCD's next poll:

```powershell
.\scripts\refresh-backstage-delivery.ps1 -ApplicationName kind-store-demo
```

Do not reintroduce a single mixed-target template that lets every user choose
AKS and Arc/kind targets. Backstage permission policy provides the portal
experience boundary; ArgoCD AppProjects enforce the deployment boundary.

The demo app path is ArgoCD-owned. The default preloaded platform demo workload is
only `platform-demo-aks-<cluster>` for AKS targets. Arc/kind application
workloads should be demonstrated through Backstage-generated GitOps PRs that
create a new ArgoCD Application in `kind-team-delivery`.

For the shared Backstage Enterprise Application, assignment is required and the
only assigned group is `akspe-backstage-users`. This means Entra blocks users
outside the common group before Backstage receives the callback, while Backstage
keeps a matching app-side check against the same single group ID.

If the ArgoCD UI shows only the local `admin` login form, or a `k8sadmin`
member signs in but sees no applications/clusters, refresh the private platform
access inputs and let ArgoCD reconcile its own add-ons:

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File .\scripts\configure-k8sadmin-access.ps1 `
  -Context gitops-aks-admin
```

## Demo flow

### 1. Show the existing management cluster

```powershell
az aks show -g aks-gitops -n gitops-aks --query "{name:name,location:location,powerState:powerState.code}" -o table
kubectl --context gitops-aks-admin get nodes
```

Talking point:

> This is the platform control plane. Application teams do not need direct Azure
> permissions to create clusters; they submit declarative cluster definitions to Git.

### 2. Show Fleet Manager

```powershell
az fleet show -g aks-gitops -n gitops-fleet --query "{name:name,hubProfile:hubProfile.dnsPrefix,provisioningState:provisioningState}" -o table
az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table
```

Expected at this point:

- `control-plane` is already a Fleet member.
- The new workload cluster member appears after AKS is ready and the Fleet
  member command is run.


### 3. Apply the cluster provisioning ApplicationSet

The repository contains an entry point that tells control-plane ArgoCD to sync
cluster definitions:

```powershell
kubectl --context gitops-aks-admin apply -f gitops/clusters/clusters-argo-applicationset.yaml
```

Then watch ArgoCD:

```powershell
kubectl --context gitops-aks-admin -n argocd get applications
kubectl --context gitops-aks-admin -n argocd get applications clusters -o yaml
```

Talking point:

> ArgoCD is now reconciling the cluster definitions path. CAPZ resources are created
> in the management cluster, and CAPZ turns them into Azure AKS resources.

### 4. Create or update a workload cluster definition

Reusable sample:

```text
gitops/clusters/capz/cluster-definitions/customer-demo.yaml
```

The `aks-workload-clusters` ApplicationSet reads files from
`gitops/clusters/capz/cluster-definitions/*.yaml` and creates one provisioning
Application per file. The included customer demo definition uses:

| Field | Demo value |
| --- | --- |
| Cluster name | `aks-customer-demo` |
| Resource group | `aks-customer-demo` |
| Fleet member | `aks-customer-demo-fleet-member` |
| Fleet group | `customer-demo` |
| Node SKU | `Standard_D4as_v6` |
| OS disk type | `Managed` |
| System pool name | `sys` |

ApplicationSet file:

```text
gitops/clusters/capz/aks-appset.yaml
```

If the demo has been disabled by renaming the file to `aks-appset.bak`, restore
or apply that file intentionally before recreating `aks-customer-demo`. The file
rename only affects future Git rendering; it does not delete a live
`aks-workload-clusters` ApplicationSet that already exists in ArgoCD.

> If demonstrating from a feature branch, keep the Git generator `revision` in
> `aks-appset.yaml` aligned with the branch ArgoCD can read. After merge, change it
> back to `main` if your control-plane GitOps Bridge tracks `main`.

### 5. Watch CAPZ create the cluster

```powershell
kubectl --context gitops-aks-admin -n workload get clusters
kubectl --context gitops-aks-admin -n workload get azuremanagedcontrolplanes
kubectl --context gitops-aks-admin -n workload get azuremanagedclusters
```

Azure side:

```powershell
az aks list -g aks-customer-demo -o table
```

Expected result:

- AKS resource is created in Azure.
- CAPZ `Cluster` eventually becomes ready.

### 6. Join and verify Fleet Manager membership

```powershell
az aks show -g aks-customer-demo -n aks-customer-demo --query provisioningState -o tsv

$aksId = az aks show -g aks-customer-demo -n aks-customer-demo --query id -o tsv
az fleet member create `
  -g aks-gitops `
  --fleet-name gitops-fleet `
  -n aks-customer-demo-fleet-member `
  --update-group customer-demo `
  --member-cluster-id $aksId

az fleet member show `
  -g aks-gitops `
  --fleet-name gitops-fleet `
  --name aks-customer-demo-fleet-member `
  --query "{name:name,group:group,provisioningState:provisioningState}" `
  -o table

az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table
```

Run `az fleet member create` only after AKS provisioning state is `Succeeded`.

Expected result:

```text
Name                            Group
------------------------------  -------------
control-plane                   control-plane
aks-customer-demo-fleet-member  customer-demo
```

Talking point:

> The workload cluster is now part of the shared Fleet Manager. Platform teams can
> use Fleet for grouped operations such as update orchestration and multi-cluster
> governance across AKS clusters.

### 7. Connect to the new workload cluster

```powershell
az aks get-credentials -g aks-customer-demo -n aks-customer-demo --overwrite-existing
kubectl config use-context aks-customer-demo
kubectl get nodes
```

### 8. Verify workload cluster GitOps

If using the existing CAPZ HelmChartProxy pattern, ArgoCD is installed into the
workload cluster:

```powershell
kubectl get pods -n argocd
kubectl get applications -n argocd
```

Get the workload ArgoCD admin password:

```powershell
kubectl get secret argocd-initial-admin-secret -n argocd --template="{{index .data.password | base64decode}}"
kubectl get svc -n argocd argo-cd-argocd-server
```

Talking point:

> The management cluster creates the workload cluster, and the workload cluster can
> then run its own ArgoCD instance for team-level application delivery.

### 9. Optional: register the workload cluster into central ArgoCD

Some customers prefer one central ArgoCD instance to target every cluster. In that
model, register the workload cluster into the control-plane ArgoCD with the
helper script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\register-aks-workload-cluster.ps1 `
  -ClusterName aks-customer-demo `
  -ResourceGroupName aks-customer-demo `
  -ControlPlaneContext gitops-aks-admin
```

Verify the cluster is visible to control-plane ArgoCD:

```powershell
kubectl --context gitops-aks-admin -n argocd get secret aks-customer-demo `
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}'

kubectl --context gitops-aks-admin -n argocd get applications -o wide

kubectl --context gitops-aks-admin -n argocd get application aks-store-demo `
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEST:.spec.destination.name
```

The script creates the equivalent ArgoCD cluster Secret in the management
ArgoCD namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aks-customer-demo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    environment: customer-demo
    provider: aks
type: Opaque
stringData:
  name: aks-customer-demo
  server: https://<aks-api-server>
  config: |
    {
      "bearerToken": "<service-account-token>",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<base64-ca>"
      }
    }
```

The script:

1. gets AKS credentials,
2. creates an `argocd-manager` service account,
3. mints a token,
4. reads the API server and CA,
5. applies the cluster Secret to the management ArgoCD namespace,
6. validates the stored token from the control-plane ArgoCD Secret.

> Note: central registration may cause GitOps Bridge ApplicationSets to target the
> workload cluster, depending on the labels/selectors in the repo. Use it when you
> intentionally want the control-plane ArgoCD to manage the workload cluster as a
> destination.

## Validation checklist

| Check | Command | Expected |
| --- | --- | --- |
| Control-plane ArgoCD healthy | `kubectl --context gitops-aks-admin -n argocd get pods` | All Running |
| Cluster provisioning app exists | `kubectl --context gitops-aks-admin -n argocd get applications` | `clusters` and workload app |
| CAPZ resources exist | `kubectl --context gitops-aks-admin -n workload get clusters` | Cluster Ready |
| AKS exists | `az aks list -g <rg> -o table` | New cluster present |
| Fleet membership | `az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table` | Workload member present |
| Platform demo ArgoCD apps | `kubectl --context gitops-aks-admin -n argocd get applications -l app.kubernetes.io/part-of=platform-demo` | `platform-demo-aks-gitops-aks` Synced / Healthy; Arc/kind workloads are demonstrated through Backstage-generated PRs |
| ArgoCD-managed demo Pods | `kubectl --context gitops-aks-admin -n group2-aks-apps get pods -l app.kubernetes.io/part-of=platform-demo` | AKS demo Pod Running |
| Workload GitOps | `kubectl --context <workload-admin> -n argocd get applications` | Apps synced if the workload cluster has its own ArgoCD |
| Arc external clusters | `az connectedk8s list -g aks-gitops -o table` | `arc-demo-vm` and `arc-demo-vm-2` Connected |
| Arc target baseline GitOps | `kubectl --context gitops-aks-admin -n argocd get application platform-target-baseline-arc-demo-vm platform-target-baseline-arc-demo-vm-2` | Both Synced / Healthy |

## Troubleshooting

### Arc demo workload applications appear

Arc/kind clusters should not receive preloaded platform demo workloads by
default. The retained Arc Applications are the `platform-target-baseline-*`
access/RBAC baselines. Customer workload deployment should be demonstrated by
Backstage generating a GitOps PR and ArgoCD Application for `group1-apps`.

Do not delete the generated child Application first; if the parent
ApplicationSet still selects the cluster Secret, it will recreate the child.
Inspect ownership and selector labels:

```powershell
kubectl --context gitops-aks-admin -n argocd get application `
  platform-demo-kind-arc-demo-vm,platform-demo-kind-arc-demo-vm-2,platform-target-baseline-arc-demo-vm,platform-target-baseline-arc-demo-vm-2 `
  --ignore-not-found `
  -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].name,SYNC:.status.sync.status,HEALTH:.status.health.status

kubectl --context gitops-aks-admin -n argocd get secret arc-demo-vm arc-demo-vm-2 `
  -o custom-columns=NAME:.metadata.name,PLATFORM_DEMO_WORKLOAD:.metadata.labels.platform_demo_workload_enabled,PLATFORM_ACCESS:.metadata.labels.platform_access_enabled,TYPE:.metadata.labels.platform_cluster_type
```

The current default is:

- keep `platform-target-baseline-arc-demo-vm` and
  `platform-target-baseline-arc-demo-vm-2`;
- generate `platform-demo-kind-*` only when the corresponding cluster Secret has
  `platform_demo_workload_enabled=true`.

After ArgoCD syncs this Git change, `platform-demo-kind-*` should stop being
recreated. If old `group1-apps` demo resources remain after the generated
Applications are gone, remove only the now-unmanaged demo workload resources:

```powershell
kubectl --context arc-demo-vm-admin -n group1-apps delete deploy,svc,cm,secret -l app.kubernetes.io/part-of=platform-demo --ignore-not-found
kubectl --context arc-demo-vm-2-admin -n group1-apps delete deploy,svc,cm,secret -l app.kubernetes.io/part-of=platform-demo --ignore-not-found
```

Do not delete `platform-target-baseline-*`; those are access/RBAC baselines used
by Backstage and the customer demo.

### ArgoCD does not create cluster resources

Check:

```powershell
kubectl --context gitops-aks-admin -n argocd get application clusters -o yaml
kubectl --context gitops-aks-admin -n argocd logs deploy/argo-cd-argocd-repo-server
```

Common causes:

- Git branch in `addons_repo_revision` does not contain the cluster definition.
- `clusters-argo-applicationset.yaml` has not been applied.
- CAPZ add-on is not healthy.

### `aks-customer-demo` reappears after deleting it in ArgoCD

`aks-customer-demo` is generated by the live `aks-workload-clusters`
ApplicationSet. Deleting only the generated `Application` in the ArgoCD UI is
temporary; the ApplicationSet controller recreates it while both of these remain
true:

- live ApplicationSet `argocd/aks-workload-clusters` exists; and
- a matching cluster definition exists under
  `gitops/clusters/capz/cluster-definitions/*.yaml`.

Check the generator and owner:

```powershell
kubectl --context gitops-aks-admin -n argocd get applicationset aks-workload-clusters -o yaml
kubectl --context gitops-aks-admin -n argocd get application aks-customer-demo `
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OWNER:.metadata.ownerReferences[*].name
```

If `OWNER` is `aks-workload-clusters`, remove or pause the generator before
deleting the generated application.

Renaming `gitops/clusters/capz/aks-appset.yaml` to `aks-appset.bak` in Git is
not enough by itself if the live `aks-workload-clusters` ApplicationSet already
exists. The parent `clusters` app must prune it, or you must delete the live
ApplicationSet explicitly:

```powershell
kubectl --context gitops-aks-admin -n argocd delete applicationset aks-workload-clusters --ignore-not-found
```

Then delete the generated application if it remains:

```powershell
kubectl --context gitops-aks-admin -n argocd delete application aks-customer-demo --ignore-not-found
```

If you want to stop future recreation from Git, also remove or rename the
cluster definition file and commit/push the change:

```text
gitops/clusters/capz/cluster-definitions/customer-demo.yaml
```

### Fleet member does not appear

Check Azure AKS and Fleet state:

```powershell
az aks show -g aks-customer-demo -n aks-customer-demo --query provisioningState -o tsv
az fleet member show `
  -g aks-gitops `
  --fleet-name gitops-fleet `
  --name aks-customer-demo-fleet-member `
  --query "{name:name,group:group,provisioningState:provisioningState}" `
  -o table
az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table
```

Common causes:

- AKS is still `Updating`; wait for `Succeeded`, then rerun `az fleet member create`.
- Fleet name/resource group are wrong.
- The Azure CLI identity lacks Fleet Manager permissions.

### Workload cluster exists but apps are not installed

Check HelmChartProxy:

```powershell
kubectl --context gitops-aks-admin get helmchartproxy -A
kubectl --context gitops-aks-admin describe helmchartproxy argocd -n default
```

Common causes:

- Cluster labels do not match HelmChartProxy selector.
- Workload cluster API is not reachable from the management cluster.

## Delete the demo

Because this demo cluster is created by ArgoCD and CAPZ, deleting only the Azure
AKS resource is not enough. ArgoCD still has desired state and CAPZ may keep
showing failed/stale objects or try to recreate the cluster.

1. Remove the desired state from the Git branch ArgoCD tracks:

```powershell
Rename-Item .\gitops\clusters\capz\aks-appset.yaml aks-appset.bak
Rename-Item .\gitops\clusters\capz\cluster-definitions\customer-demo.yaml customer-demo.yaml.bak
git add -A .\gitops\clusters\capz
git commit -m "Disable aks-customer-demo provisioning"
git push
```

2. Delete ArgoCD and CAPZ objects from the control-plane cluster:

```powershell
kubectl --context gitops-aks-admin -n argocd delete applicationset aks-workload-clusters --ignore-not-found
kubectl --context gitops-aks-admin -n argocd delete application aks-customer-demo --ignore-not-found
kubectl --context gitops-aks-admin -n argocd delete secret aks-customer-demo --ignore-not-found

kubectl --context gitops-aks-admin -n workload delete cluster aks-customer-demo --ignore-not-found --wait=false
kubectl --context gitops-aks-admin -n workload delete azuremanagedcontrolplane aks-customer-demo --ignore-not-found --wait=false
kubectl --context gitops-aks-admin -n workload delete azuremanagedcluster aks-customer-demo --ignore-not-found --wait=false
```

3. Delete Fleet member and Azure resources:

```powershell
az fleet member delete `
  -g aks-gitops `
  --fleet-name gitops-fleet `
  --name aks-customer-demo-fleet-member `
  --yes

az aks delete -g aks-customer-demo -n aks-customer-demo --yes
az group delete -n aks-customer-demo --yes
```

4. Verify deletion:

```powershell
kubectl --context gitops-aks-admin -n argocd get applications | Select-String aks-customer-demo
kubectl --context gitops-aks-admin -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster | Select-String aks-customer-demo
kubectl --context gitops-aks-admin -n workload get cluster,azuremanagedcontrolplane,azuremanagedcluster | Select-String aks-customer-demo

az fleet member show -g aks-gitops --fleet-name gitops-fleet --name aks-customer-demo-fleet-member
az aks show -g aks-customer-demo -n aks-customer-demo
az group show -n aks-customer-demo
```

All commands should return no `aks-customer-demo` resources.

> If cluster creation fails with `AKSCapacityHeavyUsage`, update `location` in
> `customer-demo.yaml` to another AKS-supported region with available capacity
> before recreating the cluster.

## Presenter notes

- Emphasize Git as the API for platform teams.
- Show ArgoCD before and after the cluster definition is committed.
- Show Fleet membership after provisioning completes.
- Explain the difference between AKS workload clusters (Fleet) and external clusters
  (Azure Arc).
- For Portal demos on Arc clusters, explain that Azure Portal uses Arc
  cluster-connect and `kube-aad-proxy`, while ArgoCD uses the private kind API
  path (`10.52.x.x:6443`). Portal resource browsing can be slower than ArgoCD's
  private API path.
- Use the `akspe-arc-portal-users` Entra group for human Portal access; use
  managed identities for onboarding and automation.
- Use `k8sadmin` as the single platform administrator group for AKS admin,
  kind-cluster admin, ArgoCD admin, and Backstage administration.
- Use `akspe-kind-cluster-deployers` for approved kind GitOps delivery, and
  `akspe-aks-cluster-deployers` for approved AKS GitOps delivery. Keep
  deployment writes namespace-scoped.
- Keep customer expectations clear: cluster creation can take several minutes and
  incurs Azure cost.
