# Devtron POC foundation

This runbook covers the Devtron self-service deployment portal POC on `gitops-aks`, including the AKS system pool baseline, Entra SSO groups, namespace-scoped deployer RBAC, and external kind cluster registration model.

> Related: use `docs/create-aks-cluster-argocd-fleet-demo.md` for AKS/Fleet/ArgoCD and `docs/arc-kubernetes-onboarding.md` for Azure Arc-enabled Kubernetes onboarding.

## `gitops-aks` system pool baseline

`gitops-aks` hosts the control-plane GitOps components and is also the preferred
place to run the optional Devtron POC because it has private VNet reachability to
the VM-hosted kind APIs. Use a `Standard_D4as_v6` system pool for this demo so
ArgoCD, Fleet/CAPZ components, Backstage, and Devtron have enough headroom.

The desired Terraform baseline is:

| Pool | Mode | VM size | Autoscaling |
| --- | --- | --- | --- |
| `system` | System | `Standard_D4as_v6` | enabled |

When resizing an existing cluster, keep the final pool name as `system` and use
AKS default node pool rotation. The Terraform module passes
`temporary_name_for_rotation`, which allows a temporary system pool to be created
during rotation while preserving the stable final pool name.

Validate the live baseline before installing Devtron:

```powershell
az aks nodepool list `
  -g aks-gitops `
  --cluster-name gitops-aks `
  --query "[].{name:name,mode:mode,vmSize:vmSize,count:count,min:minCount,max:maxCount,provisioningState:provisioningState}" `
  -o table

kubectl --context gitops-aks get nodes -o wide
kubectl --context gitops-aks -n argocd get pods
```

## Devtron self-service deployment portal

Devtron can be added as a self-service deployment portal for teams that need a
UI-driven app delivery experience across the associated clusters. It should be
positioned as an application deployment portal, not as a replacement for Fleet,
Arc, or the existing ArgoCD platform baseline.

For the live POC, Devtron is installed on `gitops-aks` in namespace `devtroncd`.
Use the dashboard path on the Devtron service:

```text
http://4.152.73.233/dashboard/
```

The default admin password is stored only in the Kubernetes secret
`devtroncd/devtron-secret` and should not be committed. Decode it before using
it in the Devtron UI; the raw `.data.ADMIN_PASSWORD` value is base64 and will
not work as the password:

```powershell
$adminPasswordBase64 = kubectl --context gitops-aks -n devtroncd get secret devtron-secret `
  -o jsonpath='{.data.ADMIN_PASSWORD}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($adminPasswordBase64))
```

Log in at `http://4.152.73.233/dashboard/` with username `admin` and the
decoded password. If troubleshooting through the API, post to
`/orchestrator/api/v1/session`; `/dashboard/orchestrator/api/v1/session` is not
the login API path.

This POC uses a patched local Helm chart artifact for installation because the
upstream Devtron `cicd` chart templates Argo Workflow CRDs as ordinary resources.
`gitops-aks` already has Argo Workflows installed as a platform add-on, so the
Devtron install must not take ownership of those cluster-wide CRDs.

## Install Devtron on Kubernetes

Use these steps for a repeatable Devtron install on `gitops-aks` or another
Kubernetes cluster that has enough capacity and network reachability to the
target clusters. For this POC, `gitops-aks` is the preferred host because it can
reach the VM-hosted kind API servers on the private `10.52.0.0/16` VNet.

Prerequisites:

- Kubernetes context for the host cluster, for example `gitops-aks`.
- Helm 3.
- A default system pool with enough headroom for Devtron, PostgreSQL, NATS,
  ArgoCD/Dex components, and GitOps services. For this demo, use
  `Standard_D4as_v6`.
- No ownership conflict with existing platform CRDs. If Argo Workflows CRDs are
  already installed by another platform component, do not let the Devtron chart
  take ownership of those CRDs.

For a clean Kubernetes cluster without existing ArgoCD or Argo Workflow CRD
ownership conflicts, install Devtron from the official Helm repository:

```powershell
helm repo add devtron https://helm.devtron.ai
helm repo update

helm upgrade --install devtron devtron/devtron-operator `
  --create-namespace `
  --namespace devtroncd `
  --wait `
  --timeout 30m
```

For this `gitops-aks` POC, the install used a local chart artifact instead of a
direct repository install because existing platform Argo Workflow CRDs caused
Helm ownership conflicts. Keep that workaround outside Git and install the
patched chart artifact from the session files:

```powershell
$chartPath = "<session-files>\devtron-chart\devtron-operator"

helm dependency build $chartPath

helm upgrade --install devtron $chartPath `
  --create-namespace `
  --namespace devtroncd `
  --wait `
  --timeout 30m
```

If the `app-sync` hook is blocked by an upstream chart download issue, do not
delete the core Devtron workloads. Confirm the dashboard, orchestrator,
PostgreSQL, NATS, Git Sensor, Kubelink, Kubewatch, and Lens pods are healthy,
then handle the blocked app-sync job separately:

```powershell
kubectl --context gitops-aks -n devtroncd get pods
kubectl --context gitops-aks -n devtroncd get deploy,statefulset
kubectl --context gitops-aks -n devtroncd logs deploy/devtron --tail=100
```

Expose the UI through a LoadBalancer service for the POC:

```powershell
kubectl --context gitops-aks -n devtroncd get svc devtron-service -o wide
```

The current live POC endpoint is:

```text
http://4.152.73.233/dashboard/
```

Use the `/dashboard/` path for the UI. The API login path is
`/orchestrator/api/v1/session`; do not post login requests to
`/dashboard/orchestrator/api/v1/session`.

## Configure Devtron after installation

Complete the initial configuration in this order:

1. Log in with the local `admin` account and the decoded
   `devtron-secret` password.
2. Configure Microsoft SSO from **Global Configurations -> Authorization -> SSO
   Login Services -> Microsoft**.
3. Register target clusters using Kubernetes service-account kubeconfigs that
   are scoped to the correct team namespace.
4. Create Devtron projects and environments.
5. Map Entra groups to Devtron permission groups.
6. Validate that users can deploy only to their assigned project, environment,
   cluster, and namespace.

For SSO, use the `akspe-devtron-sso` app registration and the redirect URI
shown by Devtron after opening the Microsoft SSO configuration page. Keep the
client secret outside Git. The app should emit security group claims so Devtron
can map users to permission groups based on Entra group membership.

For target cluster registration, prefer private Kubernetes API endpoints from
the `gitops-aks` VNet:

| Target cluster | API server | Namespace | Devtron deployer identity |
| --- | --- | --- | --- |
| `arc-demo-vm` | `https://10.52.0.4:6443` | `team-a-dev` | `devtron-team-a-deployer` |
| `arc-demo-vm-2` | `https://10.52.0.10:6443` | `team-b-dev` | `devtron-team-b-deployer` |

Do not register these clusters through the Azure Portal / Arc relay path for
Devtron deployments. Arc cluster-connect is useful for human Portal browsing,
but Devtron should use the private API path for lower latency and more stable
GitOps-style delivery.

Recommended responsibility split:

| Component | Responsibility |
| --- | --- |
| Fleet Manager | AKS fleet membership and AKS estate governance |
| Azure Arc | Azure resource view and cluster-connect for non-AKS / external clusters |
| ArgoCD | Platform GitOps baseline, add-ons, and private-network reconciliation |
| Azure Portal | Ordinary-user inspection and simple namespace-scoped Arc operations |
| Devtron | Team self-service CI/CD and app deployment with project/environment RBAC |

Devtron can register the current target clusters if it runs somewhere with
network reachability to their Kubernetes APIs. For this demo, install Devtron in
`gitops-aks` or another cluster with VNet access to `10.52.0.0/16` so it can use
the private kind API path instead of the slower Azure Portal / Arc relay path.

| Target cluster | Devtron registration path | Notes |
| --- | --- | --- |
| `gitops-aks` | In-cluster or kubeconfig registration | Good place to host Devtron |
| AKS workload clusters | Kubeconfig or service-account token | Map project environments to AKS namespaces |
| `arc-demo-vm` | Private API `https://10.52.0.4:6443` | Register as external Kubernetes from the VNet |
| `arc-demo-vm-2` | Private API `https://10.52.0.10:6443` | Register as external Kubernetes from the VNet |

Access should use two layers:

1. Devtron RBAC decides which users can see and deploy which projects,
   applications, and environments.
2. Kubernetes RBAC decides what Devtron's deployer service account can actually
   do in the target namespace.

Example mapping:

| Entra group | Object ID | Devtron project | Devtron environments | Target clusters/namespaces |
| --- | --- | --- | --- | --- |
| `team-a-devtron-users` | `4319bd61-59be-46d6-9a70-0d3e8a8e3950` | `team-a` | `team-a-dev` | `arc-demo-vm` / namespace `team-a-dev` |
| `team-b-devtron-users` | `320612d6-8d77-4703-b527-d082db5f5134` | `team-b` | `team-b-dev` | `arc-demo-vm-2` / namespace `team-b-dev` |
| `platform-devtron-admins` | `2d028374-1af8-4556-9cb9-2dd2dd54176c` | platform/admin | all | all clusters |

Use SSO for authentication, then map SSO users/groups to Devtron teams and
permission groups. SSO proves who the user is; Devtron RBAC controls what they
can deploy.

The POC Entra app registration is:

| App registration | Client ID | Group claims |
| --- | --- | --- |
| `akspe-devtron-sso` | `c04afb30-0a8c-46cc-8927-def8f3d33cfd` | `SecurityGroup` |

Store the client secret outside Git. In the current live environment, the secret
was written only to a session artifact under `files/devtron/`.

For stronger isolation, create one namespace-scoped deployer service account per
project/environment on each target cluster:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a-dev
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: devtron-team-a-deployer
  namespace: team-a-dev
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: devtron-team-a-deployer
  namespace: team-a-dev
rules:
  - apiGroups: [""]
    resources: ["configmaps", "pods", "pods/log", "secrets", "services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: devtron-team-a-deployer
  namespace: team-a-dev
subjects:
  - kind: ServiceAccount
    name: devtron-team-a-deployer
    namespace: team-a-dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: devtron-team-a-deployer
```

Then configure the Devtron environment so `team-a` deploys only to
`team-a-dev` using that service account. This keeps the blast radius scoped even
if someone accidentally grants broader Devtron UI visibility.

The reusable no-secret manifest for both demo namespaces is:

```text
gitops/apps/devtron-team-rbac/devtron-team-rbac.yaml
```

In the live POC, the generated kubeconfig artifacts are stored outside Git:

```text
files/devtron/arc-demo-vm-devtron-deployer.kubeconfig
files/devtron/arc-demo-vm-2-devtron-deployer.kubeconfig
```

Use those kubeconfigs when registering the two external clusters in Devtron:

| Devtron target name | Server URL | Namespace | Credential |
| --- | --- | --- | --- |
| `arc-demo-vm` | `https://10.52.0.4:6443` | `team-a-dev` | `devtron-team-a-deployer` |
| `arc-demo-vm-2` | `https://10.52.0.10:6443` | `team-b-dev` | `devtron-team-b-deployer` |

After registration, create Devtron projects/environments:

1. `team-a` project -> `team-a-dev` environment -> `arc-demo-vm/team-a-dev`.
2. `team-b` project -> `team-b-dev` environment -> `arc-demo-vm-2/team-b-dev`.
3. Permission group `team-a-devtron-users` can deploy only to `team-a`.
4. Permission group `team-b-devtron-users` can deploy only to `team-b`.
5. Permission group `platform-devtron-admins` has platform/admin access.

For Microsoft SSO, open Devtron's **Global Configurations -> Authorization ->
SSO Login Services -> Microsoft** page, copy the redirect URI shown by Devtron,
and ensure it is present on the `akspe-devtron-sso` app registration. The app is
already configured to emit security group claims; Devtron permission group names
should exactly match the Entra group display names when using auto-assignment.

The Microsoft SSO button is not shown on the login page until SSO is configured
and saved from the admin session. Use the local `admin` login first, complete
the Microsoft SSO configuration, then log out and verify the SSO button appears.

Validate namespace isolation from `gitops-aks` with the generated credentials:

```powershell
Write-Host "Expected: allowed=true in the assigned namespace, allowed=false in default."
kubectl --context gitops-aks -n devtroncd get secret devtron-arc-demo-vm-deployer
kubectl --context gitops-aks -n devtroncd get secret devtron-arc-demo-vm-2-deployer
```

Avoid overlapping ownership with ArgoCD:

- ArgoCD owns platform namespaces, add-ons, cluster bootstrap, and baseline apps.
- Devtron owns team application namespaces and app deployment pipelines.
- Do not let ArgoCD and Devtron manage the same Kubernetes objects.
