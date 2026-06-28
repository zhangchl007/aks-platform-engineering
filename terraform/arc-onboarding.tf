################################################################################
# Azure Arc-enabled Kubernetes — Phase 2 (Onboarding + ArgoCD integration)
#
# Boundary rule (see arc-fleet.tf):
#   * AKS Fleet Manager governs AKS clusters only.
#   * Azure Arc is reserved for NON-AKS / external Kubernetes clusters
#     (on-prem, edge, kind/k3s, other clouds). Do NOT Arc-connect the AKS hub.
#
# What this file does:
#   * Grants the akspe workload identity the RBAC needed to onboard and use
#     Arc-enabled Kubernetes clusters (scoped to the resource group).
#   * Emits a consolidated `arc_onboarding` output consumed by the idempotent
#     onboarding script (scripts/arc-onboard.*) which performs the actual
#     `az connectedk8s connect` against the target cluster and registers it
#     into the control-plane ArgoCD as a managed cluster.
#
# What this file intentionally does NOT do:
#   * It does not run `az connectedk8s connect` (that needs the target cluster
#     kubeconfig + an agent Helm install and is therefore script-driven, in
#     keeping with the repo's hook/script style).
#   * Resource-provider registration is handled in arc-fleet.tf and gated behind
#     var.register_providers (the Arc providers are already listed there).
################################################################################

locals {
  # Phase 2 is a no-op unless the operator declares external clusters.
  arc_onboarding_enabled = length(var.arc_external_clusters) > 0

  # Built-in role names verified against the Azure built-in role catalog:
  #   * "Kubernetes Cluster - Azure Arc Onboarding"
  #       (id 34e09817-6cbe-4d01-b1a2-e0eac5743d41) — allows creating/onboarding
  #       Microsoft.Kubernetes/connectedClusters resources.
  #   * "Azure Arc-enabled Kubernetes Cluster User Role"
  #       (id 00493d72-78f6-4148-b6c5-d3ce8e4799dd) — allows listing cluster
  #       user credentials / using the cluster-connect feature.
  arc_onboarding_roles = {
    onboarding   = "Kubernetes Cluster - Azure Arc Onboarding"
    cluster_user = "Azure Arc-enabled Kubernetes Cluster User Role"
  }
}

################################################################################
# RBAC for the akspe workload identity (resource-group scoped)
################################################################################
resource "azurerm_role_assignment" "akspe_arc_onboarding" {
  for_each = local.arc_onboarding_roles

  scope                = azurerm_resource_group.this.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.akspe.principal_id
}

################################################################################
# Consolidated onboarding context for scripts/arc-onboard.*
#
# Consume with:
#   terraform output -json arc_onboarding
################################################################################
output "arc_onboarding" {
  description = "Context the Arc onboarding script needs to connect external clusters and register them into the control-plane ArgoCD."
  value = {
    enabled              = local.arc_onboarding_enabled
    resource_group       = azurerm_resource_group.this.name
    location             = var.location
    subscription_id      = data.azurerm_subscription.current.subscription_id
    tenant_id            = data.azurerm_client_config.current.tenant_id
    akspe_client_id      = azurerm_user_assigned_identity.akspe.client_id
    control_plane_aks    = module.aks.aks_name
    argocd_namespace     = local.argocd_namespace
    addons_repo_url      = local.gitops_addons_url
    addons_repo_basepath = local.gitops_addons_basepath
    addons_repo_path     = local.gitops_addons_path
    addons_repo_revision = local.gitops_addons_revision
    # Map of logical cluster name => optional Azure region override (empty = use location).
    external_clusters = var.arc_external_clusters
  }
}
