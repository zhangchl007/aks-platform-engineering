################################################################################
# Azure Arc + AKS Fleet Manager — Phase 1 (Fleet foundation)
#
# Boundary rule:
#   * AKS Fleet Manager governs AKS clusters only (control-plane + future AKS
#     workload clusters join the fleet as members).
#   * Azure Arc is reserved for NON-AKS / external Kubernetes clusters and is
#     onboarded in a later phase (see var.arc_external_clusters).
#
# This file only stands up the fleet hub, the required RBAC for the akspe
# identity, and joins the control-plane AKS cluster. Membership automation for
# workload clusters, coordinated upgrades, Arc onboarding, and addon app YAML
# are intentionally out of scope for Phase 1.
################################################################################

################################################################################
# Resource provider registration (optional / opt-in)
#
# These providers are commonly already registered subscription-wide. Registering
# them requires elevated permissions and can fail or conflict in shared
# subscriptions, so registration is gated behind var.register_providers
# (default false). Enable it only on a subscription where these providers are
# not yet registered and the deploying identity has rights to register them.
################################################################################
locals {
  arc_fleet_required_providers = [
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation",
    "Microsoft.PolicyInsights",
  ]
}

resource "azurerm_resource_provider_registration" "arc_fleet" {
  for_each = var.register_providers ? toset(local.arc_fleet_required_providers) : toset([])
  name     = each.value
}

################################################################################
# AKS Fleet Manager (hub-based)
################################################################################
resource "azurerm_kubernetes_fleet_manager" "fleet" {
  name                = "${var.prefix}-fleet"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location

  hub_profile {
    dns_prefix = "${var.prefix}-fleet"
  }

  tags = var.tags
}

################################################################################
# RBAC for the akspe workload identity
#
# Built-in role names (verified against the Azure built-in role catalog):
#   * "Azure Kubernetes Fleet Manager RBAC Cluster Admin"
#       (id 18ab4d3d-a1bf-4477-8ad9-8359bc988f69) — full control of fleet
#       hub Kubernetes objects; scoped to the fleet.
#   * "Azure Kubernetes Fleet Manager Contributor Role"
#       (id 63bb64ad-9799-4770-b5c3-24ed299a07bf) — manage fleet + member
#       ARM resources; scoped to the resource group so the identity can manage
#       members/update runs created alongside the fleet.
################################################################################
resource "azurerm_role_assignment" "akspe_fleet_rbac_cluster_admin" {
  scope                = azurerm_kubernetes_fleet_manager.fleet.id
  role_definition_name = "Azure Kubernetes Fleet Manager RBAC Cluster Admin"
  principal_id         = azurerm_user_assigned_identity.akspe.principal_id
}

resource "azurerm_role_assignment" "akspe_fleet_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Azure Kubernetes Fleet Manager Contributor Role"
  principal_id         = azurerm_user_assigned_identity.akspe.principal_id
}

################################################################################
# Fleet membership — control-plane AKS cluster
################################################################################
resource "azurerm_kubernetes_fleet_member" "control_plane" {
  name                  = "control-plane"
  kubernetes_fleet_id   = azurerm_kubernetes_fleet_manager.fleet.id
  kubernetes_cluster_id = module.aks.aks_id
  group                 = "control-plane"
}
