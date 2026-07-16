# Devtron POC foundation

This runbook covers the Devtron self-service deployment portal POC on `gitops-aks`, including the AKS system pool baseline, Entra SSO groups, namespace-scoped deployer RBAC, and external kind cluster registration model.

> Related: use `docs/create-aks-cluster-argocd-fleet-demo.md` for AKS/Fleet/ArgoCD and `docs/arc-kubernetes-onboarding.md` for Azure Arc-enabled Kubernetes onboarding.

## `gitops-aks` system pool baseline

`gitops-aks` hosts the control-plane GitOps components and is also the preferred
place to run the optional Devtron POC because it has private VNet reachability to
the VM-hosted kind APIs. Use a `Standard_D4as_v5` system pool for this demo so
ArgoCD, Fleet/CAPZ components, Backstage, and Devtron have enough headroom.

The desired Terraform baseline is:

| Pool | Mode | VM size | Autoscaling |
| --- | --- | --- | --- |
| `system` | System | `Standard_D4as_v5` | enabled |

When resizing an existing cluster, keep the final pool name as `system` and use
AKS default node pool rotation. The Terraform module passes
`temporary_name_for_rotation`, which allows a temporary system pool to be created
during rotation while preserving the stable final pool name.

Validate the live baseline before installing Devtron:

```powershell
az aks nodepool list `
  -g aks-gitops-westus2 `
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
https://4.242.109.147/dashboard/
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

Log in at `https://4.242.109.147/dashboard/` with username `admin` and the
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
  `Standard_D4as_v5`.
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
https://4.242.109.147/dashboard/
```

Use the `/dashboard/` path for the UI. The API login path is
`/orchestrator/api/v1/session`; do not post login requests to
`/dashboard/orchestrator/api/v1/session`.

## Configure Devtron after installation

Complete the initial configuration in this order:

1. Log in with the local `admin` account and the decoded
   `devtron-secret` password.
2. Configure Microsoft Entra SSO from **Global Configurations -> Authorization
   -> SSO Login Services -> OIDC**.
3. Register target clusters using Kubernetes service-account kubeconfigs that
   are scoped to the correct team namespace.
4. Create Devtron projects and environments.
5. Map Entra groups to Devtron permission groups.
6. Validate that users can deploy only to their assigned project, environment,
   cluster, and namespace.

For the customer demo, Devtron role groups are reconciled by ArgoCD rather than
maintained as one-off database edits. The `platform-access` ArgoCD application
owns:

- `platform-access-policy`, the non-secret target policy ConfigMap;
- the Devtron access convergence Job that maps Entra groups to Devtron roles;
- the platform target baseline ApplicationSet that keeps target-cluster
  Kubernetes RBAC aligned with the same policy.

`k8sadmin` maps to Devtron super-admin. `akspe-kind-cluster-deployers` can view
kind targets and deploy only to `group1-apps` on `arc-demo-vm` and
`arc-demo-vm-2`. `akspe-aks-cluster-deployers` can view AKS targets and deploy
only to approved AKS environments, initially `gitops-aks/group2-aks-apps`.

The Kubernetes resource browser also performs a `global-environment/get`
authorization check before it opens a target. The GitOps convergence job must
therefore map helper roles in addition to the obvious app and cluster roles:

| Group | Browser/deploy roles |
| --- | --- |
| `k8sadmin` | `role:super-admin___`, `role:admin___`, and `role:clusterAdmin_<cluster>_*_*_*_*` for every target |
| `akspe-kind-cluster-deployers` | `role:view_group1-kind-apps__`, group 1 app admin roles, `role:clusterView_<kind-cluster>_group1-apps_*_*_*`, and `role:clusterEdit_<kind-cluster>_group1-apps_*_*_*` |
| `akspe-aks-cluster-deployers` | `role:view_group2-aks-apps__`, group 2 app admin roles, `role:clusterView_gitops-aks_group2-aks-apps_*_*_*`, and `role:clusterEdit_gitops-aks_group2-aks-apps_*_*_*` |

If a user can see cluster cards but gets `Error 403` in Kubernetes Resource
Browser, check for the `role:view_<project>__` helper roles and restart
`deployment/devtron` after convergence so Devtron reloads authorization state.
If browsing works but **Create Kubernetes Resource** returns
`permission-denied`, check that the group also has the namespace-scoped
`clusterEdit` role. `clusterView` is read-only; `clusterEdit` allows resource
creates/updates in the approved namespace without granting cluster-wide
`clusterAdmin`.

Devtron stores durable role-group membership in the `orchestrator` database but
enforces API access from the separate `casbin` database. The GitOps convergence
job must therefore create both the `roles` / `role_group_role_mapping` rows and
the matching `casbin_rule` grouping/policy rows for scoped `clusterEdit`. If the
main Devtron tables have `role:clusterEdit_<cluster>_<namespace>_*_*_*` but
`casbin_rule` does not, the UI still returns `permission-denied`.

For SSO, use the `akspe-devtron-sso-westus2` app registration and the redirect
URI `https://4.242.109.147/orchestrator/api/dex/callback`. Keep the client
secret outside Git. The app should emit security group claims so Devtron can map
users to permission groups based on Entra group membership.

Devtron's Microsoft SSO path uses Dex. For Entra work accounts, keep these
rules together:

| Setting | Required value | Why |
| --- | --- | --- |
| App registration group claims | `SecurityGroup` | Emits Entra group object IDs in the token for Devtron permission mapping |
| Dex scopes | `openid`, `profile`, `email` | Microsoft Graph does not expose a delegated OAuth scope named `groups` |
| Dex group handling | `insecureEnableGroups: true` | Allows Dex to pass Entra group object IDs through to Devtron |
| Dex email mapping | `preferred_username` -> `email` | Entra work accounts may not emit an `email` claim |

Use `scripts/devtron-enable-https.ps1` after HTTPS cutover or Helm recovery. It
keeps the public issuer HTTPS, removes the invalid `groups` OAuth scope, adds
the `preferred_username` email mapping, and restarts Devtron/Dex when needed.

For target cluster registration, prefer private Kubernetes API endpoints from
the `gitops-aks` VNet:

| Target cluster | API server | Namespace | Devtron deployer identity |
| --- | --- | --- | --- |
| `arc-demo-vm` | `https://10.52.0.4:6443` | `group1-apps` | `devtron-group1-deployer` |
| `arc-demo-vm-2` | `https://10.52.0.5:6443` | `group1-apps` | `devtron-group1-deployer` |
| `gitops-aks` | in-cluster / kubeconfig | `group2-aks-apps` | `devtron-group2-deployer` |

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
| `arc-demo-vm-2` | Private API `https://10.52.0.5:6443` | Register as external Kubernetes from the VNet |

Access should use two layers:

1. Devtron RBAC decides which users can see and deploy which projects,
   applications, and environments.
2. Kubernetes RBAC decides what Devtron's deployer service account can actually
   do in the target namespace.

Example mapping:

| Entra group | Object ID | Devtron project | Devtron environments | Target clusters/namespaces |
| --- | --- | --- | --- | --- |
| `k8sadmin` | `<private-k8sadmin-group-object-id>` | Devtron administrator | all | Admin visibility and operations across all Devtron projects/environments |
| `akspe-kind-cluster-deployers` | `<private-kind-deployer-group-object-id>` | `group1-kind-apps` | `g1-kind1`, `g1-kind2` | View all kind targets; deploy only to `arc-demo-vm/group1-apps` and `arc-demo-vm-2/group1-apps` |
| `akspe-aks-cluster-deployers` | `<private-aks-deployer-group-object-id>` | `group2-aks-apps` | `g2-aks` | View AKS targets; deploy only to `gitops-aks/group2-aks-apps` |

Use SSO for authentication, then map SSO users/groups to Devtron teams and
permission groups. SSO proves who the user is; Devtron RBAC controls what they
can deploy.

The POC Entra app registration is:

| App registration | Client ID | Group claims |
| --- | --- | --- |
| `akspe-devtron-sso-westus2` | `<private-shared-sso-client-id>` | `SecurityGroup` |

Store the client secret outside Git. In the current live environment, the secret
was written only to a session artifact under `files/devtron-westus2/`.

For stronger isolation, create one namespace-scoped deployer service account per
project/environment on each target cluster:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: group1-apps
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: devtron-group1-deployer
  namespace: group1-apps
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: devtron-group1-deployer
  namespace: group1-apps
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
  name: devtron-group1-deployer
  namespace: group1-apps
subjects:
  - kind: ServiceAccount
    name: devtron-group1-deployer
    namespace: group1-apps
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: devtron-group1-deployer
```

Then configure the Devtron environment so `group1-kind-apps` deploys only to
`group1-apps` on the two kind clusters using that service account. This keeps
the blast radius scoped even if someone accidentally grants broader Devtron UI
visibility.

The reusable no-secret manifest for both demo namespaces is:

```text
gitops/apps/devtron-team-rbac/devtron-team-rbac.yaml
```

For registered target clusters, that manifest also includes
`devtron-cluster-health-read`, a read-only `ClusterRole` bound to the Devtron
deployer service accounts. Devtron's cluster list and capacity pages read
cluster-scoped `namespaces`, `nodes`, `pods`, and Metrics API `nodes`/`pods`;
without those reads, the UI can show a cluster as `connection failed` even
though namespace deployments are authorized. This is intentionally read-only and
does not grant writes outside `group1-apps` on the kind clusters or
`group2-aks-apps` on `gitops-aks`.

In the live POC, the generated kubeconfig artifacts are stored outside Git:

```text
files/devtron-westus2/arc-demo-vm-devtron-group1.kubeconfig
files/devtron-westus2/arc-demo-vm-2-devtron-group1.kubeconfig
files/devtron-westus2/gitops-aks-devtron-group2.kubeconfig
```

Use those kubeconfigs when registering the two external clusters in Devtron:

| Devtron target name | Server URL | Namespace | Credential |
| --- | --- | --- | --- |
| `arc-demo-vm` | `https://10.52.0.4:6443` | `group1-apps` | `devtron-group1-deployer` |
| `arc-demo-vm-2` | `https://10.52.0.5:6443` | `group1-apps` | `devtron-group1-deployer` |
| `gitops-aks` | in-cluster / kubeconfig | `group2-aks-apps` | `devtron-group2-deployer` |

After registration, create Devtron projects/environments:

1. `group1-kind-apps` project -> `g1-kind1` environment -> `arc-demo-vm/group1-apps`.
2. `group1-kind-apps` project -> `g1-kind2` environment -> `arc-demo-vm-2/group1-apps`.
3. `group2-aks-apps` project -> `g2-aks` environment -> `gitops-aks/group2-aks-apps`.
4. Permission group `<private-k8sadmin-group-object-id>` is Devtron admin.
5. Permission group `<private-kind-deployer-group-object-id>` can view all kind targets and deploy only to `group1-kind-apps`.
6. Permission group `<private-aks-deployer-group-object-id>` can view AKS targets and deploy only to `group2-aks-apps`.

For Microsoft SSO, configure Devtron's **Global Configurations -> Authorization ->
SSO Login Services -> OIDC** page with the `akspe-devtron-sso-westus2` app
registration, and ensure the redirect URI
`https://4.242.109.147/orchestrator/api/dex/callback` is present on that app.
The app emits `SecurityGroup` claims, which are object IDs by default. For
auto-assignment, Devtron permission group names must therefore exactly match the
Entra group object IDs, not the display names.

Do not add `groups` to the OIDC scope list in Devtron. If users see
`AADSTS650053`, the invalid `groups` scope was reintroduced. If users see
`missing email claim`, the Dex `preferred_username` to `email` claim mapping is
missing. Re-run `scripts/devtron-enable-https.ps1` to restore both settings.

If a `k8sadmin` member signs in but does not have Devtron administrator access,
refresh the private platform access inputs and let the ArgoCD-managed
`platform-access` application converge Devtron role groups:

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File .\scripts\configure-k8sadmin-access.ps1 `
  -Context gitops-aks-admin
```

Then sign out and sign in again so Devtron re-evaluates the Entra `groups`
claim.

The SSO button is not shown on the login page until SSO is configured and saved
from the admin session. Use the local `admin` login first, complete the OIDC
configuration, then log out and verify the SSO button appears.

Validate namespace isolation from `gitops-aks` with the generated credentials:

```powershell
Write-Host "Expected: allowed=true in the assigned namespace, allowed=false in default."
kubectl --context arc-demo-vm-devtron-group1 auth can-i create deployments -n group1-apps
kubectl --context arc-demo-vm-devtron-group1 auth can-i create deployments -n default
kubectl --context arc-demo-vm-2-devtron-group1 auth can-i create deployments -n group1-apps
kubectl --context gitops-aks-devtron-group2 auth can-i create deployments -n group2-aks-apps
```

Also validate the cluster-health reads needed by Devtron for the `gitops-aks`
overview:

```powershell
kubectl --context gitops-aks-admin auth can-i list nodes `
  --as=system:serviceaccount:group2-aks-apps:devtron-group2-deployer
kubectl --context gitops-aks-admin auth can-i list pods --all-namespaces `
  --as=system:serviceaccount:group2-aks-apps:devtron-group2-deployer
kubectl --context gitops-aks-admin auth can-i list nodes.metrics.k8s.io `
  --as=system:serviceaccount:group2-aks-apps:devtron-group2-deployer
kubectl --context gitops-aks-admin auth can-i create pods -n group2-aks-apps `
  --as=system:serviceaccount:group2-aks-apps:devtron-group2-deployer
kubectl --context gitops-aks-admin auth can-i create deployments -n default `
  --as=system:serviceaccount:group2-aks-apps:devtron-group2-deployer
```

The first four checks should be `yes`; the final cross-namespace write check
must remain `no`.

Run the same read-only health checks against the generated kind-cluster
kubeconfigs for `devtron-group1-deployer`; the write checks should allow
`group1-apps` and deny `default`.

Avoid overlapping ownership with ArgoCD:

- ArgoCD owns platform namespaces, add-ons, cluster bootstrap, and baseline apps.
- Devtron owns team application namespaces and app deployment pipelines.
- Do not let ArgoCD and Devtron manage the same Kubernetes objects.
