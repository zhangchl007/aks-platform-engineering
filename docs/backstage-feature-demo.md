# Demo: Backstage application deployment with ArgoCD

This customer demo shows Backstage as the developer portal for **application
deployment** on AKS. Developers use a Software Template to request an app
deployment, Backstage creates a reviewable GitOps pull request, and ArgoCD
syncs the application after the pull request is approved.

The demo is intentionally app-focused. AKS cluster provisioning, Fleet Manager,
and CAPZ are separate platform demos; this walkthrough starts after a target AKS
environment and control-plane ArgoCD are already available.

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

- Backstage is deployed or available for UI walkthrough.
- Backstage GitHub integration has permission to create pull requests in the
  GitOps repository.
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

### 1. Open Backstage and explain the developer portal role

Talking point:

> Backstage does not replace GitOps or ArgoCD. It gives developers a guided,
> self-service front door that produces standardized Git changes for the
> platform team to review.

Show:

- **Catalog** for service ownership and runtime discovery.
- **Docs** for onboarding and operational guidance.
- **Create** for paved-road application deployment templates.

### 2. Open the application deployment template

In Backstage, go to **Create** and select:

```text
Deploy Application with ArgoCD
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

### 3. Run the template and review the pull request

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

### 4. Merge the pull request and let ArgoCD reconcile

After review, merge the pull request. Then check the control-plane ArgoCD
cluster:

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

### 5. Verify the workload in Kubernetes

```powershell
kubectl --context gitops-aks -n aks-store-demo get all
```

Expected result:

- Namespace `aks-store-demo` exists.
- AKS Store Demo deployments, services, and pods are created.
- Pods eventually reach `Running`.

### 6. Show the Backstage catalog entry

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
