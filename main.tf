terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

# ==============================================================================
# 1. CORE GOVERNANCE RESOURCE GROUP
# ==============================================================================
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = { Environment = var.environment, Owner = "admin" }
}

# ==============================================================================
# 2. VIRTUAL NETWORK & SUBNET SEGMENTATION
# ==============================================================================
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-poc-core"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "snet_appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "snet_apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "snet_compute" {
  name                 = "snet-integration-compute"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]
  delegation {
    name = "webapp-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "snet_pe" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/24"]
}

# ==============================================================================
# 3. OBSERVABILITY & UNIFIED LOGGING Workspace
# ==============================================================================
resource "azurerm_log_analytics_workspace" "log" {
  name                = "log-poc-central-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ==============================================================================
# 4. PRIVATE DNS ZONES & NETWORK LINKS
# ==============================================================================
resource "azurerm_private_dns_zone" "dns_kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "dns_sb" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "link_kv" {
  name                  = "lnk-kv-vnet"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dns_kv.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "link_sb" {
  name                  = "lnk-sb-vnet"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dns_sb.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# ==============================================================================
# 5. AZURE KEY VAULT WITH INBOUND PRIVATE ENDPOINT
# ==============================================================================
resource "azurerm_key_vault" "kv" {
  name                          = "kv-poc-${random_string.suffix.result}"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  public_network_access_enabled = false
}

resource "azurerm_private_endpoint" "pe_kv" {
  name                = "pe-keyvault"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.snet_pe.id

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.kv.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "dns-group-kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.dns_kv.id]
  }
}

# ==============================================================================
# 6. SERVICE BUS (PREMIUM) WITH INBOUND PRIVATE ENDPOINT
# ==============================================================================
resource "azurerm_servicebus_namespace" "sb" {
  name                          = "sb-poc-${random_string.suffix.result}"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  sku                           = "Premium"
  capacity                      = 1
  public_network_access_enabled = false
}

resource "azurerm_private_endpoint" "pe_sb" {
  name                = "pe-servicebus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.snet_pe.id

  private_service_connection {
    name                           = "psc-sb"
    private_connection_resource_id = azurerm_servicebus_namespace.sb.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "dns-group-sb"
    private_dns_zone_ids = [azurerm_private_dns_zone.dns_sb.id]
  }
}

# ==============================================================================
# 7. HIGHLY AVAILABLE CROSS-PLATFORM COMPUTE PLAN & WEB APP
# ==============================================================================
resource "azurerm_service_plan" "asp" {
  name                = "asp-poc-compute"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "P1v3"
}

resource "azurerm_linux_web_app" "webapp" {
  name                          = "app-web-${random_string.suffix.result}"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  service_plan_id               = azurerm_service_plan.asp.id
  public_network_access_enabled = false

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
  }
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_app_service_virtual_network_swift_connection" "vnet_conn_web" {
  app_service_id = azurerm_linux_web_app.webapp.id
  subnet_id      = azurerm_subnet.snet_compute.id
}

# ==============================================================================
# 8. INTERNAL VNET INJECTED API MANAGEMENT (APIM) GATEWAY
# ==============================================================================
resource "azurerm_api_management" "apim" {
  name                 = "apim-poc-${random_string.suffix.result}"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  publisher_name       = "PoC Publisher"
  publisher_email      = "admin@poc.local"
  sku_name             = "Developer_1"
  virtual_network_type = "Internal"
  virtual_network_id   = azurerm_subnet.snet_apim.id

  identity {
    type = "SystemAssigned"
  }
}

# ==============================================================================
# 9. IACO INTERNAL TLS ROOT GENERATION (SELF-SIGNED)
# ==============================================================================
resource "tls_private_key" "poc_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "poc_cert" {
  private_key_pem = tls_private_key.poc_key.private_key_pem

  subject {
    common_name  = "poc.local"
    organization = "Enterprise PoC Corp"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

# ==============================================================================
# 10. ENTRY POINT APPLICATION GATEWAY V2 WITH INTEGRATED WAF
# ==============================================================================
resource "azurerm_public_ip" "pip_agw" {
  name                = "pip-agw-poc"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "agw" {
  name                = "agw-poc-waf"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }
 gateway_ip_configuration {
    name      = "agw-ip-config"
subnet_id = azurerm_subnet.snet_appgw.id
  }
  frontend_port {
    name = "port_443"
    port = 443
  }
  frontend_ip_configuration {
    name                 = "agw-frontend-public"
    public_ip_address_id = azurerm_public_ip.pip_agw.id
  }
  backend_address_pool {
    name         = "apim-backend-pool"
    ip_addresses = ["10.0.2.254"] # Points directly to internal APIM cluster VIP
  }
  backend_http_settings {
    name                  = "apim-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }
  ssl_certificate {
    name     = "self-signed-poc-cert"
    data     = tls_self_signed_cert.poc_cert.cert_pem
    password = ""
  }
  http_listener {
    name                           = "agw-https-listener"
    frontend_ip_configuration_name = "agw-frontend-public"
    frontend_port_name             = "port_443"
    protocol                       = "Https"
    ssl_certificate_name           = "self-signed-poc-cert"
  }
  request_routing_rule {
    name                       = "rule-agw-to-apim"
    rule_type                  = "Basic"
    http_listener_name         = "agw-https-listener"
    backend_address_pool_name  = "apim-backend-pool"
    backend_http_settings_name = "apim-http-settings"
    priority                   = 100
  }
  waf_configuration {
    enabled          = true
    firewall_mode    = "Detection"
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }
}

# ==============================================================================
# 11. AUTOMATED CONSOLE OUTPUT GENERATION
# ==============================================================================

  output "application_gateway_url" {
    description = "The public endpoint URL used to safely access your secure backend topology."
    value       = "https://${azurerm_public_ip.pip_agw.ip_address}"
  }