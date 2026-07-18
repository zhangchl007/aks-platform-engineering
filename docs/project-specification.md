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

ArgoCD ordinary-user visibility SHOULD be team/persona scoped by default:
AKS deployers see `aks-team-delivery/*`, Arc/kind deployers see
`kind-team-delivery/*`, and `k8sadmin` sees all. Per-user-only visibility
requires explicit user-prefixed Application naming and per-user ArgoCD RBAC; do
not claim it unless that stricter model is implemented.

Do not create or reintroduce a single ordinary-user template that lets every
user select AKS and Arc/kind targets from one mixed list. Backstage permission
policy MUST restrict protected cluster Resources and protected delivery
templates by Entra-derived Backstage group entitlement.

The durable deployment authorization boundary remains ArgoCD AppProjects plus
reviewed Git changes. Backstage MUST NOT receive write-capable Kubernetes
credentials for ordinary deployers.

## Backstage delivery regression gates

Every change to Backstage delivery templates, delivery Scaffolder actions,
Catalog delivery lifecycle, or Backstage access policy SHOULD include or update
focused regression tests before it is accepted. At minimum:

- delivery action behavior is covered by
  `platformDeliveryActions.test.ts`;
- ordinary-user template visibility and parameter/step authorization are covered
  by `platformAccessPermissionPolicy.test.ts`;
- the Backstage image build runs the relevant targeted tests before
  `yarn build:backend`.

Backstage image builds MUST use the repository root as the Docker/ACR build
context and `backstage/Dockerfile` as the Dockerfile. The image build copies the
Backstage source plus the `gitops/` tree so `yarn catalog:validate` checks the
same delivery invariants that ArgoCD will reconcile. Building from the
`backstage/` subdirectory hides `gitops/apps/backstage-delivery` from the
validator and is not an acceptable release gate.

Update templates MUST fail before publishing a pull request when the named
application is absent or any required generated artifact is missing. They MUST
NOT default to a previously used demo application name; update workflows require
an explicit existing application name from the watched branch.

The Backstage delete template is intentionally not exposed. Cleanup is a manual
platform operation: remove the generated ArgoCD delivery directory, generated
Catalog descriptor, and matching Catalog target in one reviewed pull request so
ArgoCD can prune the resources from Git-owned desired state. Keep the
`gitops/apps/backstage-delivery` root path present in Git even when it contains
no generated applications; ArgoCD cannot prune from an Application source path
that no longer exists.

## Change acceptance criteria

A Kubernetes configuration change is acceptable only when:

1. Its desired state is represented in the GitOps source.
2. An ArgoCD Application or ApplicationSet owns the target resource.
3. Terraform has no competing Kubernetes resource management for that target.
4. Operational scripts do not leave imperative configuration drift.
5. Ordinary-user Backstage delivery uses the correct group-scoped template and
   restricted ArgoCD AppProject.
6. Backstage delivery changes include the regression gates required above.

Reviewers MUST reject changes that violate these constraints or create
overlapping ownership.
