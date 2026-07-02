# ArgoCD registration for Azure Arc-enabled clusters

This folder describes how an **Azure Arc-enabled Kubernetes** cluster (an external /
non-AKS cluster) is registered into the **control-plane ArgoCD** so it is managed by the
same GitOps control plane as the rest of the platform.

> Boundary: Azure Arc is reserved for **non-AKS / external** clusters (on-prem, edge,
> kind/k3s, other clouds). AKS clusters are governed by **Fleet Manager**, not Arc.

## How it works

1. `scripts/arc-onboard.{ps1,sh}` runs `az connectedk8s connect` to onboard the target
   cluster to Azure Arc and enables the **cluster-connect** feature.
2. The script then creates an **ArgoCD cluster Secret** (this folder's template) in the
   control-plane's `argocd` namespace. The Secret carries:
   - **labels** that the addon `ApplicationSet`s select on — notably
     `environment: arc` and `enable_arc_onboarding: "true"` (plus any curated addon
     enables you want to apply to Arc clusters).
   - **annotations** that the `ApplicationSet` templates read — the `addons_repo_*`
     coordinates and Azure identifiers.
3. ArgoCD discovers the new cluster and the
   `addons-arc-onboarding` `ApplicationSet` deploys the Arc baseline
   (`gitops/apps/arc-demo`) to prove end-to-end sync.

The broad `cluster-addons` sweep (`terraform/bootstrap/addons.yaml`) explicitly
**excludes** `environment: arc`, so external clusters receive only the curated Arc
baseline rather than the full hub addon stack.

## Files

- `cluster-secret.example.yaml` — template ArgoCD cluster Secret. The onboarding script
  substitutes the `__PLACEHOLDER__` values at runtime.

> Never commit a real cluster Secret: it contains a bearer token / connection config.
> The live Secret is created in-cluster by the script and is not stored in Git.

## Reachability note

ArgoCD (running in the control-plane AKS) must be able to reach the Arc cluster's API
endpoint. For private / on-prem clusters use the Arc **cluster-connect** tunnel or ensure
network connectivity. A local `kind` demo cluster is reachable from your workstation but
not from AKS — see `docs/arc-enabled-kubernetes.md` for the demo's scope and limits.
