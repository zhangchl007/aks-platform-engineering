# Demo: Backstage application deployment with ArgoCD

This customer demo shows Backstage as the developer portal for **application
deployment** on AKS. Developers use a Software Template to request an app
deployment, Backstage creates a reviewable GitOps pull request, and ArgoCD
syncs the application after the pull request is approved.

The demo is intentionally app-focused. AKS cluster provisioning, Fleet Manager,
and CAPZ are separate platform demos; this walkthrough starts after a target AKS
environment and control-plane ArgoCD are already available.

## Position Backstage and Devtron together

Backstage and Devtron are complementary entry points, not competing portals.
Show them as two intentional paths that use the same Microsoft Entra identity
source and remain governed by Kubernetes RBAC and GitOps boundaries.

| Customer need | Entry point | What the user does | Control boundary |
| --- | --- | --- | --- |
| Discover services, documentation, ownership, and a governed golden path | Backstage | Creates a standardized GitOps pull request for an AKS application | Pull request review, ArgoCD reconciliation, and AKS RBAC |
| Deploy and operate an approved team application across assigned environments | Devtron | Uses a project/environment-scoped CI/CD workflow | Devtron project RBAC plus namespace-scoped deployer RBAC |
| Inspect or make a simple namespace-scoped change on an external cluster | Azure Portal / Azure Arc | Browses Arc Kubernetes resources | Azure RBAC, Arc cluster-connect, and Kubernetes RBAC |
| Reconcile platform add-ons and approved GitOps definitions | ArgoCD | Platform operator view and reconciliation | Git as source of truth and ArgoCD RBAC |

Do not demonstrate Backstage as a replacement for Devtron or ArgoCD:

- **Backstage** is the developer experience and governance front door. It turns
  a guided request into a reviewable Git change.
- **Devtron** is the team delivery workspace for users who have already been
  assigned to a project, environment, cluster, and namespace.
- **ArgoCD** reconciles the approved GitOps state and owns platform baseline
  resources.
- **Azure Arc** provides the Azure management plane view for the two external
  kind clusters; Devtron uses their private Kubernetes APIs for delivery.

## Customer presentation story

Start with the problem rather than individual tools:

> Teams need a simple way to deploy safely across AKS and external Kubernetes
> clusters without receiving cluster-admin credentials or learning every GitOps
> convention. The platform therefore offers a single Entra identity, clear
> self-service entry points, and two enforcement layers: portal permissions and
> namespace-scoped Kubernetes permissions.

Use this sequence for a 10-15 minute walkthrough:

1. **Establish the platform view.** Show `gitops-aks` as the management cluster,
   the two connected Arc clusters (`arc-demo-vm` and `arc-demo-vm-2`), and
   explain that Fleet governs AKS while Arc governs external Kubernetes.
2. **Show shared identity.** Explain that Backstage, Devtron, and ArgoCD use
   the same `akspe-devtron-sso-westus2` Microsoft Entra app registration. The
   application is shared; authorization remains specific to each component.
3. **Show the governed developer path in Backstage.** Sign in to Backstage,
   open **Catalog**, then **Create**, and select **Deploy Application with
   ArgoCD**. Emphasize that the template collects standardized inputs and
   creates a pull request rather than granting direct cluster write access.
4. **Show review and reconciliation.** Open the generated pull request, point
   out the catalog entity and ArgoCD `Application`, then show the application
   in ArgoCD. Explain that Git review, policy, and the ArgoCD audit trail are
   retained.
5. **Show the team delivery path in Devtron.** Sign in to Devtron and show that
   group 1 sees only `g1-kind1` and `g1-kind2`, while group 2 sees only
   `g2-aks`. Explain that Devtron's visible scope is not the final enforcement
   boundary: each environment uses a namespace-scoped Kubernetes service
   account.
6. **Close with the isolation proof.** Show the two Arc clusters connected in
   Azure, then explain that the kind deployer group cannot access the AKS
   Devtron project or ArgoCD admin path. This is least privilege applied at
   identity, portal, GitOps, and Kubernetes layers.

### Live presentation endpoints

| Component | URL | Audience |
| --- | --- | --- |
| Backstage | `https://20.69.107.137` | Developers requesting the governed AKS golden path |
| Devtron | `https://4.242.109.147/dashboard/` | Teams deploying to assigned environments |
| ArgoCD | `https://172.179.107.194` | Platform operators and AKS deployer group |
| Azure Portal / Arc | Azure Portal | External-cluster discovery and simple Arc resource operations |

## What the customer will see

1. Backstage provides one portal for application catalog, docs, ownership, and
   golden-path templates.
2. A developer opens **Create** and selects **Deploy Application with ArgoCD**.
3. The template collects app details, source repo, manifest path, and target
   namespace.
4. Backstage creates a GitOps pull request with:
   - a Backstage `Component` catalog entity,
   - an ArgoCD `Application` manifest under `gitops/apps/<app-name>/`.
5. The platform team reviews and merges the pull request.
6. ArgoCD deploys the app to AKS and Backstage can show ownership plus
   Kubernetes visibility through the catalog entity.

```mermaid
flowchart LR
  Dev["Developer"] --> Portal["Backstage<br/>Developer Portal"]
  Portal --> Template["Software Template<br/>Deploy app"]
  Template --> PR["GitHub Pull Request<br/>catalog + ArgoCD app"]
  PR --> Argo["Control-plane ArgoCD"]
  Argo --> AKS["AKS workload cluster"]
  AKS --> App["Application namespace<br/>and workloads"]
  Portal --> Catalog["Backstage Catalog<br/>service ownership"]
  Catalog --> App
```

## Demo prerequisites

- Backstage is deployed by Terraform with `build_backstage=true` or is otherwise
  available for UI walkthrough. The live POC endpoint is
  `https://20.69.107.137`.
- Backstage GitHub integration has permission to create pull requests in the
  GitOps repository. For this repo, Terraform passes `github_token` into the
  Backstage Helm release as `GITHUB_TOKEN`.
- Microsoft Entra SSO is configured with the shared demo app registration
  `akspe-devtron-sso-westus2`. The Backstage callback URL is
  `https://20.69.107.137/api/auth/microsoft/handler/frame`.
- Backstage allows Microsoft Entra sign-in for members of the privately
  configured `backstage_allowed_group_object_ids`. It dynamically maps the email
  local part to a Backstage identity, so every user in the allowed group can log
  in without being pre-created in `backstage/packages/examples/org.yaml`.
- Backstage catalog includes the application deployment template:

```yaml
catalog:
  locations:
    - type: file
      target: ./examples/template/template.yaml
      rules:
        - allow: [Template]
```

- Control-plane ArgoCD is running and watching this GitOps repository.
- The target app repository contains Kubernetes manifests or a Kustomize overlay.
  The default demo app uses:

```text
https://github.com/Azure-Samples/aks-store-demo.git
kustomize/overlays/dev
```

## Demo assets in this repository

| Asset | Purpose |
| --- | --- |
| `backstage/packages/examples/template/template.yaml` | Backstage Software Template shown in the **Create** page |
| `backstage/packages/examples/template/content/catalog-info.yaml` | Backstage service catalog entity rendered by the template |
| `backstage/packages/examples/template/content/gitops/apps/myapp/petArgoApp.yaml` | Template source for the generated ArgoCD `Application` |
| `gitops/apps/myapp/AKSStoreDemoArgoApp.yaml` | Checked-in sample ArgoCD app for the AKS Store Demo |

## Demo flow

### 1. Find the Backstage URL

Backstage is exposed through a `LoadBalancer` service in the `backstage`
namespace. From the repo root or any shell with the `gitops-aks` kube context:

```powershell
kubectl --context gitops-aks -n backstage get pods
kubectl --context gitops-aks -n backstage get svc
```

Look for the Backstage service external IP. With the Terraform-deployed Helm
release, the service is usually:

```powershell
kubectl --context gitops-aks -n backstage get svc backstage-backstagechart
```

Open Backstage with HTTPS:

```text
https://<BACKSTAGE_EXTERNAL_IP>
```

For the live POC, open:

```text
https://20.69.107.137
```

Only use the public IP directly for a short-lived demo after Microsoft Entra
authentication is configured. Do not expose an unauthenticated Backstage instance
at this address. For shared or production environments, place Backstage behind an
authenticated ingress or application gateway, restrict source networks, and
prefer a DNS name with a trusted certificate over direct public-IP access.

If the browser shows a certificate warning, continue for the demo. The sample
uses a self-signed certificate unless you replace it with a trusted certificate.

You can also get the Terraform-managed public IP from Azure. First get the AKS
node resource group:

```powershell
$nodeResourceGroup = az aks show -g aks-gitops -n gitops-aks --query nodeResourceGroup -o tsv
```

Then query the Backstage public IP:

```powershell
az network public-ip show `
  -g $nodeResourceGroup `
  -n backstage-public-ip `
  --query ipAddress `
  -o tsv
```

### 2. Log in to Backstage

1. Open `https://20.69.107.137`.
2. On the Backstage sign-in page, choose **Microsoft Entra ID**.
3. Complete the Entra sign-in flow with an account that belongs to the allowed
   Backstage demo Entra group.
4. After login, confirm that the Backstage home page loads.

If login succeeds but your user is not recognized, check the Backstage logs:

```powershell
kubectl --context gitops-aks -n backstage logs deploy/backstage-backstagechart
```

Common fixes:

- Confirm the shared Entra app has callback URL
  `https://20.69.107.137/api/auth/microsoft/handler/frame`.
- Confirm `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` were
  rendered into the Backstage Helm release.
- Confirm `BACKSTAGE_ALLOWED_GROUP_IDS` is configured from private tfvars and
  the shared Entra app registration emits `SecurityGroup` claims.
- Restart Backstage after OAuth or catalog configuration changes:

  ```powershell
  kubectl --context gitops-aks -n backstage rollout restart deploy/backstage-backstagechart
  ```

### 3. Explain the developer portal role

Talking point:

> Backstage does not replace GitOps or ArgoCD. It gives developers a guided,
> self-service front door that produces standardized Git changes for the
> platform team to review.

Show:

- **Catalog** for service ownership and runtime discovery.
- **Docs** for onboarding and operational guidance.
- **Create** for paved-road application deployment templates.

### 4. Open the application deployment template

In Backstage, go to **Create** and select:

```text
Deploy Application with ArgoCD
```

This template is registered from:

```text
backstage/packages/examples/template/template.yaml
```

Use these demo values:

| Field | Demo value |
| --- | --- |
| Application name | `aks-store-demo` |
| Kubernetes namespace | `aks-store-demo` |
| Service owner | `platform-engineering` |
| Application repository | `github.com?owner=Azure-Samples&repo=aks-store-demo` |
| Manifest path | `kustomize/overlays/dev` |
| Target revision | `HEAD` |
| GitOps repository | `github.com?owner=zhangchl007&repo=aks-platform-engineering` |
| Pull request title | `Add AKS Store Demo application` |
| Commit message | `Add AKS Store Demo application GitOps definition` |

### 5. Run the template and review the pull request

1. Click **Next** through the template form.
2. Review the collected values.
3. Click **Create**.
4. Wait for the scaffolder task to finish.

Expected Backstage output:

- A GitHub pull request link.
- A generated catalog entity at:

```text
catalog-info.yaml
```

- A generated ArgoCD app manifest at:

```text
gitops/apps/aks-store-demo/aks-store-demo-argocd-app.yaml
```

The generated ArgoCD `Application` uses:

```yaml
metadata:
  name: aks-store-demo
  namespace: argocd
  annotations:
    backstage.io/kubernetes-id: aks-store-demo
spec:
  source:
    repoURL: https://github.com/Azure-Samples/aks-store-demo.git
    targetRevision: HEAD
    path: kustomize/overlays/dev
  destination:
    namespace: aks-store-demo
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Talking point:

> The developer does not need to hand-write ArgoCD YAML or request direct
> cluster permissions. Backstage generates the expected GitOps contract, and the
> platform team keeps review, policy, and audit in GitHub.

### 6. Merge the pull request and let ArgoCD reconcile

Open the pull request from the Backstage task output, review the generated files,
and merge it into the branch that control-plane ArgoCD watches.

Then check the control-plane ArgoCD cluster:

```powershell
kubectl --context gitops-aks -n argocd get applications
kubectl --context gitops-aks -n argocd get application aks-store-demo -o wide
```

Expected result:

```text
NAME             SYNC STATUS   HEALTH STATUS
aks-store-demo   Synced        Healthy
```

If automated sync is disabled in your environment, trigger a sync manually:

```powershell
argocd app sync aks-store-demo
```

If the `argocd` CLI is not logged in, use the ArgoCD UI to sync the app or log in
with the control-plane ArgoCD endpoint and admin password.

### 7. Verify the workload in Kubernetes

```powershell
kubectl --context gitops-aks -n aks-store-demo get all
```

Expected result:

- Namespace `aks-store-demo` exists.
- AKS Store Demo deployments, services, and pods are created.
- Pods eventually reach `Running`.

If the application exposes a service, list it with:

```powershell
kubectl --context gitops-aks -n aks-store-demo get svc
```

### 8. Show the Backstage catalog entry

Open **Catalog** and search for:

```text
aks-store-demo
```

Highlight:

- service ownership,
- source repository link,
- Kubernetes annotation `backstage.io/kubernetes-id: aks-store-demo`,
- how platform teams can add TechDocs, scorecards, dependencies, and runtime
  health around the same service entity.

## Customer talking points

- **Standardization:** every app follows the same ArgoCD manifest pattern.
- **Governance:** deployment changes are pull requests, not ad hoc cluster
  changes.
- **Developer experience:** developers use a form and catalog instead of
  learning every GitOps file path.
- **Extensibility:** the same template can add policy labels, namespaces,
  secrets integration, OpenTelemetry defaults, or environment promotion.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Template is not visible in Backstage | Confirm `./examples/template/template.yaml` is registered in `catalog.locations`. |
| Pull request creation fails | Check GitHub token permissions for repository contents and pull requests. |
| ArgoCD app stays `OutOfSync` | Confirm the generated file is under the repo path watched by ArgoCD and the PR was merged to the watched branch. |
| ArgoCD app is `Degraded` | Check the app repo path, image pull status, and Kubernetes events in the target namespace. |
| Backstage catalog does not show Kubernetes data | Confirm the generated `catalog-info.yaml` and ArgoCD manifest use the same `backstage.io/kubernetes-id` value. |

## Optional CLI validation

Validate the template YAML and generated source files before presenting:

```powershell
& 'C:\Program Files\nodejs\npx.cmd' --yes js-yaml backstage\packages\examples\template\template.yaml
& 'C:\Program Files\nodejs\npx.cmd' --yes js-yaml backstage\packages\examples\template\content\catalog-info.yaml
& 'C:\Program Files\nodejs\npx.cmd' --yes js-yaml backstage\packages\examples\template\content\gitops\apps\myapp\petArgoApp.yaml
```
