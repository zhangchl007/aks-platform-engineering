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
  arc_kind_vm_enabled    = var.enable_arc_kind_vm
  arc_kind_vm_cluster    = "arc-demo-vm"
  arc_kind_vm_subnet_id  = lookup(module.network.vnet_subnets_name_id, "aks")
  arc_kind_vm_vnet_cidr  = module.network.vnet_address_space[0]
  arc_kind_vm_api_source = module.network.vnet_address_space[0]
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

output "arc_kind_vm" {
  description = "Private VM-hosted kind demo cluster context."
  value = local.arc_kind_vm_enabled ? {
    vm_name      = azurerm_linux_virtual_machine.arc_kind_vm[0].name
    private_ip   = azurerm_network_interface.arc_kind_vm[0].private_ip_address
    api_server   = "https://${azurerm_network_interface.arc_kind_vm[0].private_ip_address}:${var.arc_kind_vm_api_port}"
    cluster_name = local.arc_kind_vm_cluster
  } : null
}
