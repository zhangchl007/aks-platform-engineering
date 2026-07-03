################################################################################
# Azure Arc + AKS Fleet Manager - Fleet foundation
#
# Boundary rule:
#   * AKS Fleet Manager governs AKS clusters only (control-plane + future AKS
#     workload clusters join the fleet as members).
#   * Azure Arc is reserved for NON-AKS / external Kubernetes clusters
#     (on-prem, edge, kind/k3s, other clouds).
#
# This file stands up the Fleet Manager hub, grants the akspe identity Fleet
# permissions, and joins the control-plane AKS cluster as the initial member.
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
# Fleet membership - control-plane AKS cluster
################################################################################
resource "azurerm_kubernetes_fleet_member" "control_plane" {
  name                  = "control-plane"
  kubernetes_fleet_id   = azurerm_kubernetes_fleet_manager.fleet.id
  kubernetes_cluster_id = module.aks.aks_id
  group                 = "control-plane"
}
