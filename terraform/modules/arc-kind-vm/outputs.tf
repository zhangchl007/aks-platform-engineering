output "cluster" {
  description = "Connection details for the private VM-hosted kind cluster."
  value = {
    vm_name            = azurerm_linux_virtual_machine.this.name
    private_ip         = azurerm_network_interface.this.private_ip_address
    outbound_public_ip = azurerm_public_ip.outbound.ip_address
    api_server         = "https://${azurerm_network_interface.this.private_ip_address}:${var.api_port}"
    cluster_name       = var.cluster_name
    api_port           = var.api_port
  }
}
