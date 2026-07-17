resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "kind_api_from_vnet" {
  name                        = "AllowKindApiFromVnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.api_port)
  source_address_prefix       = var.vnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

resource "azurerm_public_ip" "outbound" {
  name                = "${var.name}-outbound-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.outbound.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.size
  admin_username      = var.admin_username
  tags                = var.tags

  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.admin.public_key_openssh
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

resource "azurerm_role_assignment" "onboarding" {
  for_each = var.onboarding_roles

  scope                = var.resource_group_id
  role_definition_name = each.value
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

locals {
  portal_rbac_documents = var.portal_access == null ? [] : [
    yamlencode({
      apiVersion = "v1"
      kind       = "Namespace"
      metadata = {
        name = var.portal_access.namespace
        labels = {
          "access-model" = "azure-portal-arc"
        }
      }
    }),
    yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "Role"
      metadata = {
        name      = "portal-demo-editor"
        namespace = var.portal_access.namespace
      }
      rules = [
        {
          apiGroups = [""]
          resources = ["configmaps", "pods", "pods/log", "secrets", "services"]
          verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
        },
        {
          apiGroups = ["apps"]
          resources = ["deployments", "replicasets", "statefulsets"]
          verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
        }
      ]
    }),
    yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "RoleBinding"
      metadata = {
        name      = "portal-demo-private-access"
        namespace = var.portal_access.namespace
      }
      subjects = [
        for subject in var.portal_access.subjects : {
          kind     = subject.kubernetes_kind
          name     = subject.kubernetes_name
          apiGroup = "rbac.authorization.k8s.io"
        }
      ]
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "Role"
        name     = "portal-demo-editor"
      }
    }),
    var.portal_access.portal_browser_compatible ? yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "ClusterRoleBinding"
      metadata = {
        name = "portal-demo-browser-read"
        labels = {
          "access-model"              = "azure-portal-arc"
          "portal-browser-compatible" = "true"
        }
      }
      subjects = [
        for subject in var.portal_access.subjects : {
          kind     = subject.kubernetes_kind
          name     = subject.kubernetes_name
          apiGroup = "rbac.authorization.k8s.io"
        }
      ]
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "ClusterRole"
        name     = "view"
      }
    }) : null
  ]

  portal_role_assignments = var.portal_access == null ? {} : {
    for assignment in flatten([
      for subject in var.portal_access.subjects : [
        for role_name in [
          "Azure Arc Enabled Kubernetes Cluster User Role",
          "Azure Arc Kubernetes Viewer",
          "Azure Arc Kubernetes Writer"
          ] : {
          key            = "${subject.azure_principal_id}-${role_name}"
          principal_id   = subject.azure_principal_id
          principal_type = subject.azure_principal_type
          role_name      = role_name
        }
      ]
    ]) : assignment.key => assignment
  }
}

resource "azurerm_virtual_machine_run_command" "bootstrap" {
  name               = "arc-kind-bootstrap"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.this.id

  source {
    script = <<-SCRIPT
      #!/bin/sh
      set -eu

      bootstrap_config="$${1}"
      old_ifs="$${IFS}"
      IFS='|'
      set -- $${bootstrap_config}
      IFS="$${old_ifs}"
      cluster_name="$${1}"
      resource_group="$${2}"
      location="$${3}"
      subscription_id="$${4}"
      private_ip="$${5}"
      api_port="$${6}"
      portal_rbac_base64="$${7}"
      bootstrap_revision="$${8}"

      export DEBIAN_FRONTEND=noninteractive
      export KUBECONFIG=/root/.kube/config
      mkdir -p /opt/arc-kind /root/.kube

      apt-get update -y
      apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https docker.io
      systemctl enable --now docker

      if ! command -v az >/dev/null 2>&1; then
        curl -sL https://aka.ms/InstallAzureCLIDeb | sh
      fi
      if ! command -v kubectl >/dev/null 2>&1; then
        curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x /usr/local/bin/kubectl
      fi
      if ! command -v kind >/dev/null 2>&1; then
        curl -fsSL -o /usr/local/bin/kind https://github.com/kubernetes-sigs/kind/releases/download/v0.24.0/kind-linux-amd64
        chmod +x /usr/local/bin/kind
      fi

      cat >/opt/arc-kind/kind.yaml <<EOF
      kind: Cluster
      apiVersion: kind.x-k8s.io/v1alpha4
      networking:
        apiServerAddress: "$${private_ip}"
        apiServerPort: $${api_port}
      nodes:
        - role: control-plane
      EOF

      if ! kind get clusters | grep -qx "$${cluster_name}"; then
        kind create cluster --name "$${cluster_name}" --config /opt/arc-kind/kind.yaml --wait 180s
      fi
      docker update --restart=unless-stopped "$${cluster_name}-control-plane" >/dev/null
      kubectl config use-context "kind-$${cluster_name}" >/dev/null
      kubectl get nodes

      az login --identity --allow-no-subscriptions >/dev/null
      az account set --subscription "$${subscription_id}"
      az extension add --name connectedk8s --upgrade --only-show-errors >/dev/null

      existing="$(az connectedk8s list --resource-group "$${resource_group}" --query "[?name=='$${cluster_name}'].id | [0]" -o tsv)"
      arc_namespace="$(kubectl get namespace azure-arc --ignore-not-found -o name)"
      if [ -z "$${existing}" ] || [ -z "$${arc_namespace}" ]; then
        az connectedk8s connect --name "$${cluster_name}" --resource-group "$${resource_group}" --location "$${location}" --kube-context "kind-$${cluster_name}" --only-show-errors
      fi
      az connectedk8s enable-features --name "$${cluster_name}" --resource-group "$${resource_group}" --kube-context "kind-$${cluster_name}" --features cluster-connect --only-show-errors

      if [ -n "$${portal_rbac_base64}" ]; then
        printf '%s' "$${portal_rbac_base64}" | base64 -d >/tmp/portal-rbac.yaml
        kubectl apply -f /tmp/portal-rbac.yaml
      fi

      printf '%s\n' "$${bootstrap_revision}" >/opt/arc-kind/bootstrap-revision
    SCRIPT
  }

  protected_parameter {
    name = "bootstrap_config"
    value = join("|", [
      var.cluster_name,
      var.resource_group_name,
      var.location,
      var.subscription_id,
      azurerm_network_interface.this.private_ip_address,
      tostring(var.api_port),
      base64encode(join("\n---\n", compact(local.portal_rbac_documents))),
      var.bootstrap_revision
    ])
  }

  depends_on = [
    azurerm_role_assignment.onboarding,
    azurerm_network_interface_security_group_association.this
  ]
}

resource "azurerm_role_assignment" "portal_access" {
  for_each = local.portal_role_assignments

  scope                = "${var.resource_group_id}/providers/Microsoft.Kubernetes/connectedClusters/${var.cluster_name}"
  role_definition_name = each.value.role_name
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type

  depends_on = [azurerm_virtual_machine_run_command.bootstrap]
}
