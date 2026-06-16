data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                = "ov-${var.environment}-kv"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  # No public access — secrets only reachable from within the VNet.
  public_network_access_enabled = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }
}

# Grant the ACA apps' managed identity read access to secrets.
resource "azurerm_key_vault_access_policy" "aca" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.aca.principal_id

  secret_permissions = ["Get", "List"]
}

resource "azurerm_user_assigned_identity" "aca" {
  name                = "ov-${var.environment}-aca-identity"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# DATABASE_URL points at the currently active blue/green database.
# The nightly pipeline updates this secret and rolls the apps to promote.
resource "azurerm_key_vault_secret" "database_url" {
  name         = "DATABASE-URL"
  key_vault_id = azurerm_key_vault.main.id
  value = "postgresql://ovadmin:${random_password.postgres_admin.result}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/app_${var.active_db}?sslmode=require"
}

resource "azurerm_key_vault_secret" "redis_url" {
  name         = "REDIS-URL"
  key_vault_id = azurerm_key_vault.main.id
  value        = "rediss://:${azurerm_redis_cache.main.primary_access_key}@${azurerm_redis_cache.main.hostname}:6380"
}

resource "azurerm_key_vault_secret" "legacy_db_password" {
  name         = "OV-DB-PASSWORD"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.legacy_db_password
}

resource "azurerm_key_vault_secret" "rails_master_key" {
  name         = "RAILS-MASTER-KEY"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.rails_master_key
}

# Postgres admin password stored for the migration job's direct DB access.
resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "POSTGRES-ADMIN-PASSWORD"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.postgres_admin.result
}
