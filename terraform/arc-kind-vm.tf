################################################################################
# Private Azure VM-hosted kind cluster demo
#
# Purpose:
#   Host a non-AKS demo Kubernetes cluster on an Azure VM whose API server is
#   reachable from the AKS-hosted ArgoCD over the existing VNet. This fixes the
#   laptop-kind limitation where ArgoCD sees https://127.0.0.1:<port>.
#
# Boundary:
#   This is still an external/non-AKS cluster and is therefore governed through
#   Azure Arc + ArgoCD, not Fleet Manager.
################################################################################

locals {
  arc_kind_vm_enabled     = var.enable_arc_kind_vm
  arc_kind_vm_cluster     = "arc-demo-vm"
  arc_kind_vm_subnet_id   = lookup(module.network.vnet_subnets_name_id, "aks")
  arc_kind_vm_vnet_cidr   = module.network.vnet_address_space[0]
  arc_kind_vm_api_source  = module.network.vnet_address_space[0]
  additional_arc_kind_vms = var.additional_arc_kind_vms
  additional_arc_kind_vm_role_map = {
    for item in flatten([
      for vm_name, _ in local.additional_arc_kind_vms : [
        for role_key, role_name in local.arc_onboarding_roles : {
          key       = "${vm_name}-${role_key}"
          vm_name   = vm_name
          role_name = role_name
        }
      ]
    ]) : item.key => item
  }
}

resource "tls_private_key" "arc_kind_vm_admin" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_security_group" "arc_kind_vm" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  name                = "${var.arc_kind_vm_name}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "arc_kind_api_from_vnet" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  name                        = "AllowKindApiFromVnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.arc_kind_vm_api_port)
  source_address_prefix       = local.arc_kind_vm_api_source
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.arc_kind_vm[0].name
}

resource "azurerm_public_ip" "arc_kind_vm_outbound" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  name                = "${var.arc_kind_vm_name}-outbound-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "arc_kind_vm" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  name                = "${var.arc_kind_vm_name}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.arc_kind_vm_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.arc_kind_vm_outbound[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "arc_kind_vm" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  network_interface_id      = azurerm_network_interface.arc_kind_vm[0].id
  network_security_group_id = azurerm_network_security_group.arc_kind_vm[0].id
}

resource "azurerm_linux_virtual_machine" "arc_kind_vm" {
  count = local.arc_kind_vm_enabled ? 1 : 0

  name                = var.arc_kind_vm_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.arc_kind_vm_size
  admin_username      = var.arc_kind_vm_admin_username
  tags                = var.tags

  disk_controller_type                                   = "NVMe"
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.arc_kind_vm[0].id]

  admin_ssh_key {
    username   = var.arc_kind_vm_admin_username
    public_key = tls_private_key.arc_kind_vm_admin[0].public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_role_assignment" "arc_kind_vm_onboarding" {
  for_each = local.arc_kind_vm_enabled ? local.arc_onboarding_roles : {}

  scope                = azurerm_resource_group.this.id
  role_definition_name = each.value
  principal_id         = azurerm_linux_virtual_machine.arc_kind_vm[0].identity[0].principal_id
}

resource "tls_private_key" "additional_arc_kind_vm_admin" {
  for_each = local.additional_arc_kind_vms

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_security_group" "additional_arc_kind_vm" {
  for_each = local.additional_arc_kind_vms

  name                = "${each.key}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "additional_arc_kind_api_from_vnet" {
  for_each = local.additional_arc_kind_vms

  name                        = "AllowKindApiFromVnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.api_port)
  source_address_prefix       = local.arc_kind_vm_api_source
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.additional_arc_kind_vm[each.key].name
}

resource "azurerm_public_ip" "additional_arc_kind_vm_outbound" {
  for_each = local.additional_arc_kind_vms

  name                = "${each.key}-outbound-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "additional_arc_kind_vm" {
  for_each = local.additional_arc_kind_vms

  name                = "${each.key}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.arc_kind_vm_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.additional_arc_kind_vm_outbound[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "additional_arc_kind_vm" {
  for_each = local.additional_arc_kind_vms

  network_interface_id      = azurerm_network_interface.additional_arc_kind_vm[each.key].id
  network_security_group_id = azurerm_network_security_group.additional_arc_kind_vm[each.key].id
}

resource "azurerm_linux_virtual_machine" "additional_arc_kind_vm" {
  for_each = local.additional_arc_kind_vms

  name                = each.key
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = each.value.size
  admin_username      = each.value.admin_username
  tags                = var.tags

  disk_controller_type                                   = "NVMe"
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.additional_arc_kind_vm[each.key].id]

  admin_ssh_key {
    username   = each.value.admin_username
    public_key = tls_private_key.additional_arc_kind_vm_admin[each.key].public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_role_assignment" "additional_arc_kind_vm_onboarding" {
  for_each = local.additional_arc_kind_vm_role_map

  scope                = azurerm_resource_group.this.id
  role_definition_name = each.value.role_name
  principal_id         = azurerm_linux_virtual_machine.additional_arc_kind_vm[each.value.vm_name].identity[0].principal_id
}

output "arc_kind_vm" {
  description = "Private VM-hosted kind demo cluster context."
  value = local.arc_kind_vm_enabled ? {
    vm_name            = azurerm_linux_virtual_machine.arc_kind_vm[0].name
    private_ip         = azurerm_network_interface.arc_kind_vm[0].private_ip_address
    outbound_public_ip = azurerm_public_ip.arc_kind_vm_outbound[0].ip_address
    api_server         = "https://${azurerm_network_interface.arc_kind_vm[0].private_ip_address}:${var.arc_kind_vm_api_port}"
    cluster_name       = local.arc_kind_vm_cluster
    api_port           = var.arc_kind_vm_api_port
  } : null
}

output "arc_kind_vms" {
  description = "Map of private VM-hosted kind demo clusters, keyed by Azure VM name."
  value = merge(
    local.arc_kind_vm_enabled ? {
      (azurerm_linux_virtual_machine.arc_kind_vm[0].name) = {
        vm_name            = azurerm_linux_virtual_machine.arc_kind_vm[0].name
        private_ip         = azurerm_network_interface.arc_kind_vm[0].private_ip_address
        outbound_public_ip = azurerm_public_ip.arc_kind_vm_outbound[0].ip_address
        api_server         = "https://${azurerm_network_interface.arc_kind_vm[0].private_ip_address}:${var.arc_kind_vm_api_port}"
        cluster_name       = local.arc_kind_vm_cluster
        api_port           = var.arc_kind_vm_api_port
      }
    } : {},
    {
      for vm_name, vm in azurerm_linux_virtual_machine.additional_arc_kind_vm : vm_name => {
        vm_name            = vm.name
        private_ip         = azurerm_network_interface.additional_arc_kind_vm[vm_name].private_ip_address
        outbound_public_ip = azurerm_public_ip.additional_arc_kind_vm_outbound[vm_name].ip_address
        api_server         = "https://${azurerm_network_interface.additional_arc_kind_vm[vm_name].private_ip_address}:${local.additional_arc_kind_vms[vm_name].api_port}"
        cluster_name       = local.additional_arc_kind_vms[vm_name].cluster_name
        api_port           = local.additional_arc_kind_vms[vm_name].api_port
      }
    }
  )
}
