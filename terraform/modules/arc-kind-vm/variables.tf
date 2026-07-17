variable "name" {
  description = "Azure VM name. The module also uses this name as the map key in the parent configuration."
  type        = string
}

variable "cluster_name" {
  description = "Azure Arc connected-cluster name that will be assigned during onboarding."
  type        = string
}

variable "location" {
  description = "Azure region for the VM networking resources."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that contains the VM and supporting networking resources."
  type        = string
}

variable "resource_group_id" {
  description = "Resource group ID used as the scope for Arc onboarding role assignments."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID used by the VM managed identity during Arc onboarding."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID used by the VM NIC."
  type        = string
}

variable "vnet_cidr" {
  description = "VNet CIDR allowed to reach the private kind Kubernetes API."
  type        = string
}

variable "size" {
  description = "Azure VM SKU."
  type        = string
}

variable "admin_username" {
  description = "Linux administrator username. Password authentication remains disabled."
  type        = string
}

variable "api_port" {
  description = "Private TCP port exposed by the kind Kubernetes API."
  type        = number

  validation {
    condition     = var.api_port > 0 && var.api_port < 65536
    error_message = "api_port must be between 1 and 65535."
  }
}

variable "onboarding_roles" {
  description = "Azure built-in roles assigned to the VM managed identity for Arc onboarding."
  type        = map(string)
}

variable "portal_access" {
  description = "Optional private configuration for namespace-scoped Portal subjects."
  type        = any
  default     = null
}

variable "bootstrap_revision" {
  description = "Environment-controlled value that reruns the idempotent VM bootstrap when changed."
  type        = string
}

variable "tags" {
  description = "Tags applied to VM and network resources."
  type        = map(string)
}
