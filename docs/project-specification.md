# Project specification

This document defines mandatory platform design constraints. It takes
precedence over convenience scripts, legacy implementation patterns, and
one-off operational procedures.

## Kubernetes configuration ownership

**ArgoCD is the sole continuous manager of all Kubernetes configuration.**

All Kubernetes desired state MUST be versioned in the GitOps repository and
reconciled by ArgoCD. This includes:

- platform add-ons and cluster baselines;
- application workloads and namespaces;
- Kubernetes RBAC, network policy, ConfigMaps, and Secrets;
- ArgoCD Applications, AppProjects, and repository/cluster registration;
- Backstage workloads, reader RBAC, and configuration;
- configuration targeting AKS and Azure Arc-connected clusters.

Terraform MUST manage Azure infrastructure only. It MAY create the minimum
one-time Kubernetes bootstrap required to install ArgoCD and its root
Application or ApplicationSet. That bootstrap exception ends when ArgoCD is
available to reconcile the target configuration.

After ArgoCD adoption, Terraform, `kubectl apply`, imperative Deployment
patches, Helm commands, and scripts MUST NOT continuously manage or mutate
ArgoCD-owned Kubernetes resources. Changes MUST be made through an approved
GitOps path and reconciled by ArgoCD.

## Secret bootstrap exception

Credentials that cannot be committed to Git MAY be created or rotated through a
documented secure bootstrap procedure. The resulting Secret MUST be referenced
by an ArgoCD-managed workload, and this exception MUST NOT be used to introduce
another continuous Kubernetes configuration controller.

## Backstage delivery entry points

Backstage is the guided portal experience, not the continuous Kubernetes
reconciler. Ordinary-user delivery MUST be split by audience and target type:

- AKS deployers use an AKS-specific template that renders Applications in the
  `aks-team-delivery` AppProject.
- Arc/kind deployers use an Arc/kind-specific template that renders
  Applications in the `kind-team-delivery` AppProject.
- `k8sadmin` may see both paths for platform administration and testing.

Do not create or reintroduce a single ordinary-user template that lets every
user select AKS and Arc/kind targets from one mixed list. Backstage permission
policy MUST restrict protected cluster Resources and protected delivery
templates by Entra-derived Backstage group entitlement.

The durable deployment authorization boundary remains ArgoCD AppProjects plus
reviewed Git changes. Backstage MUST NOT receive write-capable Kubernetes
credentials for ordinary deployers.

## Change acceptance criteria

A Kubernetes configuration change is acceptable only when:

1. Its desired state is represented in the GitOps source.
2. An ArgoCD Application or ApplicationSet owns the target resource.
3. Terraform has no competing Kubernetes resource management for that target.
4. Operational scripts do not leave imperative configuration drift.
5. Ordinary-user Backstage delivery uses the correct group-scoped template and
   restricted ArgoCD AppProject.

Reviewers MUST reject changes that violate these constraints or create
overlapping ownership.
