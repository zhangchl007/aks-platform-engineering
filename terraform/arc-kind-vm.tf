################################################################################
# Private Azure VM-hosted kind cluster demo
#
# Every VM-hosted kind cluster is defined in var.arc_kind_vms and instantiated
# by the same module. This makes adding clusters additive and avoids duplicating
# VM, NIC, NSG, public IP, managed identity, and Arc onboarding RBAC resources.
################################################################################

module "arc_kind_vm" {
  source   = "./modules/arc-kind-vm"
  for_each = var.arc_kind_vms

  name                = each.key
  cluster_name        = each.value.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  resource_group_id   = azurerm_resource_group.this.id
  subnet_id           = lookup(module.network.vnet_subnets_name_id, "aks")
  vnet_cidr           = module.network.vnet_address_space[0]
  size                = each.value.size
  admin_username      = each.value.admin_username
  api_port            = each.value.api_port
  onboarding_roles    = local.arc_onboarding_roles
  tags                = var.tags
}

# Preserve the original output consumed by existing automation.
output "arc_kind_vm" {
  description = "Legacy connection context for the original VM-hosted kind demo cluster."
  value       = try(module.arc_kind_vm["arc-kind-vm"].cluster, null)
}

output "arc_kind_vms" {
  description = "Map of private VM-hosted kind demo clusters, keyed by Azure VM name."
  value = {
    for vm_name, instance in module.arc_kind_vm :
    vm_name => instance.cluster
  }
}

# Preserve the identities of the two already deployed clusters when the
# duplicated resources are moved into the reusable module.
moved {
  from = tls_private_key.arc_kind_vm_admin[0]
  to   = module.arc_kind_vm["arc-kind-vm"].tls_private_key.admin
}

moved {
  from = azurerm_network_security_group.arc_kind_vm[0]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_network_security_group.this
}

moved {
  from = azurerm_network_security_rule.arc_kind_api_from_vnet[0]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_network_security_rule.kind_api_from_vnet
}

moved {
  from = azurerm_public_ip.arc_kind_vm_outbound[0]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_public_ip.outbound
}

moved {
  from = azurerm_network_interface.arc_kind_vm[0]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_network_interface.this
}

moved {
  from = azurerm_network_interface_security_group_association.arc_kind_vm[0]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_network_interface_security_group_association.this
}

moved {
  from = azurerm_linux_virtual_machine.arc_kind_vm[0]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_linux_virtual_machine.this
}

moved {
  from = azurerm_role_assignment.arc_kind_vm_onboarding["onboarding"]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_role_assignment.onboarding["onboarding"]
}

moved {
  from = azurerm_role_assignment.arc_kind_vm_onboarding["cluster_user"]
  to   = module.arc_kind_vm["arc-kind-vm"].azurerm_role_assignment.onboarding["cluster_user"]
}

moved {
  from = tls_private_key.additional_arc_kind_vm_admin["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].tls_private_key.admin
}

moved {
  from = azurerm_network_security_group.additional_arc_kind_vm["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_network_security_group.this
}

moved {
  from = azurerm_network_security_rule.additional_arc_kind_api_from_vnet["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_network_security_rule.kind_api_from_vnet
}

moved {
  from = azurerm_public_ip.additional_arc_kind_vm_outbound["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_public_ip.outbound
}

moved {
  from = azurerm_network_interface.additional_arc_kind_vm["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_network_interface.this
}

moved {
  from = azurerm_network_interface_security_group_association.additional_arc_kind_vm["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_network_interface_security_group_association.this
}

moved {
  from = azurerm_linux_virtual_machine.additional_arc_kind_vm["arc-kind-vm-2"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_linux_virtual_machine.this
}

moved {
  from = azurerm_role_assignment.additional_arc_kind_vm_onboarding["arc-kind-vm-2-onboarding"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_role_assignment.onboarding["onboarding"]
}

moved {
  from = azurerm_role_assignment.additional_arc_kind_vm_onboarding["arc-kind-vm-2-cluster_user"]
  to   = module.arc_kind_vm["arc-kind-vm-2"].azurerm_role_assignment.onboarding["cluster_user"]
}
