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

## Change acceptance criteria

A Kubernetes configuration change is acceptable only when:

1. Its desired state is represented in the GitOps source.
2. An ArgoCD Application or ApplicationSet owns the target resource.
3. Terraform has no competing Kubernetes resource management for that target.
4. Operational scripts do not leave imperative configuration drift.

Reviewers MUST reject changes that violate these constraints or create
overlapping ownership.
