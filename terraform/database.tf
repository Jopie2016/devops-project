resource "random_password" "postgres_admin" {
  length  = 32
  special = true
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "ov-${var.environment}-pg"
  location               = azurerm_resource_group.main.location
  resource_group_name    = azurerm_resource_group.main.name
  version                = "17"
  administrator_login    = "ovadmin"
  administrator_password = random_password.postgres_admin.result

  # Standard_D2ds_v5 (2 vCPU, 8 GB) is right-sized for ~300 users.
  # Upgrade to D4ds if query latency becomes a concern post-cutover.
  sku_name   = "GP_Standard_D2ds_v5"
  storage_mb = 131072 # 128 GB — slightly above the ~100 GB DB size for headroom

  high_availability {
    mode = "ZoneRedundant"
  }

  backup_retention_days        = 14
  geo_redundant_backup_enabled = false

  # No public network access — reachable only via private endpoint.
  public_network_access_enabled = false
}

# Blue database — serves traffic on even nights (or initially).
resource "azurerm_postgresql_flexible_server_database" "blue" {
  name      = "app_blue"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# Green database — serves traffic on odd nights after first swap.
resource "azurerm_postgresql_flexible_server_database" "green" {
  name      = "app_green"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_private_endpoint" "postgres" {
  name                = "ov-postgres-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "postgres-psc"
    private_connection_resource_id = azurerm_postgresql_flexible_server.main.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "postgres-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.postgres.id]
  }
}

# Redis — single instance, three logical DBs (cable=0, cache=1, sidekiq=2).
resource "azurerm_redis_cache" "main" {
  name                = "ov-${var.environment}-redis"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # C2 Standard (6 GB) is ample for cable/cache/sidekiq at this scale.
  sku_name = "Standard"
  family   = "C"
  capacity = 2

  enable_non_ssl_port           = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  redis_configuration {
    maxmemory_policy = "allkeys-lru"
  }
}

resource "azurerm_private_endpoint" "redis" {
  name                = "ov-redis-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "redis-psc"
    private_connection_resource_id = azurerm_redis_cache.main.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
}
