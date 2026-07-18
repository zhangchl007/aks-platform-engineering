# Repository instructions

Follow `docs/project-specification.md` as the authoritative project
specification.

## Mandatory preflight for every change

Before proposing, editing, or validating any change that touches Kubernetes,
ArgoCD, Backstage delivery, Terraform, Helm, scripts, or GitOps paths:

1. Read `docs/project-specification.md` in the current working tree.
2. Identify whether the change is:
   - Azure infrastructure bootstrap, or
   - Kubernetes/ArgoCD/Backstage desired state.
3. Identify the owning ArgoCD Application or ApplicationSet for every
   Kubernetes desired-state change.
4. If the change would place post-bootstrap Kubernetes configuration in
   Terraform, Helm CLI commands, `kubectl apply`, imperative patches, or scripts,
   stop and move the change into the GitOps source instead.
5. Do not implement until the ownership path is clear. If ownership is unclear,
   state that explicitly and inspect the GitOps Applications/ApplicationSets
   before editing.

When summarizing a Kubernetes, ArgoCD, Backstage delivery, or Terraform change,
include the ownership decision in the final response, for example:
`Ownership: ArgoCD Application <name> reconciles <path/resource>.`

## Kubernetes configuration ownership

- Treat ArgoCD as the sole continuous manager of every Kubernetes resource and
  configuration in this repository.
- Put Kubernetes desired-state changes in the GitOps source and ensure an
  ArgoCD Application or ApplicationSet owns them.
- Do not add or retain Terraform Kubernetes resources, Helm releases, direct
  `kubectl apply` workflows, imperative patches, or scripts that continuously
  mutate an ArgoCD-owned Kubernetes resource.
- Terraform is limited to Azure infrastructure and the minimum one-time
  bootstrap needed to install ArgoCD and its root Application or ApplicationSet.
- For credentials that cannot be stored in Git, use the documented secure
  bootstrap Secret procedure only. Reference the resulting Secret
  declaratively from an ArgoCD-managed workload; do not create a competing
  configuration controller.
- Before proposing or implementing a Kubernetes change, identify the owning
  ArgoCD Application or ApplicationSet and avoid overlapping ownership.
