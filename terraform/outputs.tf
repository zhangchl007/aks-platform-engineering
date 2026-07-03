output "subscription_id" {
  description = "Specifies the subscription id."
  value       = data.azurerm_subscription.current.subscription_id
}

output "tenant" {
  description = "Specifies the tenant id."
  value       = data.azurerm_client_config.current.tenant_id
}

output "akspe_client_id" {
  description = "Specifies the client id used for user MSI to use for workload identity auth with CAPZ/Crossplane."
  value       = azurerm_user_assigned_identity.akspe.client_id
}

output "backstage_public_ip" {
  description = "Static public IP assigned to the Backstage LoadBalancer service. Null when build_backstage=false."
  value       = length(azurerm_public_ip.backstage_public_ip) > 0 ? azurerm_public_ip.backstage_public_ip[0].ip_address : null
}

output "backstage_base_url" {
  description = "Public Backstage base URL used for browser access and OAuth app configuration. Null when build_backstage=false."
  value       = length(azurerm_public_ip.backstage_public_ip) > 0 ? "https://${azurerm_public_ip.backstage_public_ip[0].ip_address}" : null
}

output "backstage_github_oauth_callback_url" {
  description = "GitHub OAuth Authorization callback URL for the Backstage GitHub auth provider. Null when build_backstage=false."
  value       = length(azurerm_public_ip.backstage_public_ip) > 0 ? "https://${azurerm_public_ip.backstage_public_ip[0].ip_address}/api/auth/github/handler/frame" : null
}