# Repository instructions

Follow `docs/project-specification.md` as the authoritative project
specification.

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
