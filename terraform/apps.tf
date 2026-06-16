resource "azurerm_container_registry" "main" {
  name                = "ovacr${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  admin_enabled       = false
}

# Grant ACA identity pull access to ACR.
resource "azurerm_role_assignment" "aca_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aca.principal_id
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "ov-${var.environment}-logs"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "main" {
  name                       = "ov-${var.environment}-env"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  # VNet-integrated so apps reach Postgres/Redis via private endpoints.
  infrastructure_subnet_id = azurerm_subnet.aca.id
}

locals {
  # Shared environment variables injected into all three workloads.
  common_env = [
    { name = "RAILS_ENV", value = "production" },
    { name = "OV_DB_HOST", value = var.legacy_db_host },
    { name = "OV_DB_PORT", value = "1433" },
    { name = "OV_DB_NAME", value = var.legacy_db_name },
    { name = "OV_DB_USERNAME", value = var.legacy_db_username },
  ]
  # ACA secret names must be lowercase alphanumeric/'-'. We map each Key Vault
  # secret to a lowercase ACA secret name, then expose it to the app under its
  # real (upper-case) env-var name via secret_name.
  common_secrets = [
    { env = "DATABASE_URL", secret = "database-url", kv = azurerm_key_vault_secret.database_url.id },
    { env = "REDIS_URL", secret = "redis-url", kv = azurerm_key_vault_secret.redis_url.id },
    { env = "OV_DB_PASSWORD", secret = "ov-db-password", kv = azurerm_key_vault_secret.legacy_db_password.id },
    { env = "RAILS_MASTER_KEY", secret = "rails-master-key", kv = azurerm_key_vault_secret.rails_master_key.id },
  ]
}

# Web process — Puma. Scales on inbound HTTP concurrency.
resource "azurerm_container_app" "web" {
  name                         = "ov-web"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Multiple" # enables rolling deploys

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aca.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.aca.id
  }

  # Pull each secret from Key Vault using the app's managed identity.
  dynamic "secret" {
    for_each = local.common_secrets
    content {
      name                = secret.value.secret
      key_vault_secret_id = secret.value.kv
      identity            = azurerm_user_assigned_identity.aca.id
    }
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "http" # ACA upgrades WS connections automatically

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 2
    max_replicas = 6

    container {
      name    = "web"
      image   = var.app_image
      cpu     = 1.0
      memory  = "2Gi"
      command = ["bundle", "exec", "puma", "-C", "config/puma.rb"]

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      # Secret-backed env vars (DATABASE_URL, REDIS_URL, etc.).
      dynamic "env" {
        for_each = local.common_secrets
        content {
          name        = env.value.env
          secret_name = env.value.secret
        }
      }
    }

    http_scale_rule {
      name                = "http-scaler"
      concurrent_requests = 50
    }
  }
}

# Worker process — Sidekiq. Scales on queue depth via KEDA.
resource "azurerm_container_app" "worker" {
  name                         = "ov-worker"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aca.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.aca.id
  }

  dynamic "secret" {
    for_each = local.common_secrets
    content {
      name                = secret.value.secret
      key_vault_secret_id = secret.value.kv
      identity            = azurerm_user_assigned_identity.aca.id
    }
  }

  template {
    min_replicas = 1
    max_replicas = 4

    container {
      name    = "worker"
      image   = var.app_image
      cpu     = 1.0
      memory  = "2Gi"
      command = ["bundle", "exec", "sidekiq"]

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.common_secrets
        content {
          name        = env.value.env
          secret_name = env.value.secret
        }
      }
    }

    custom_scale_rule {
      name             = "sidekiq-queue-depth"
      custom_rule_type = "redis"
      metadata = {
        redisAddress = "rediss://${azurerm_redis_cache.main.hostname}:6380"
        listName     = "queue:default"
        listLength   = "10"
      }
    }
  }
}

# Migration job — runs bin/migrate all nightly. No timeout; run-to-completion.
resource "azurerm_container_app_job" "migration" {
  name                         = "ov-migration-job"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id

  # Triggered externally by the GitHub Actions nightly workflow.
  # The workflow calls az containerapp job start and polls for completion.
  replica_timeout_in_seconds = 50400 # 14 hours — covers worst-case audit-log run
  replica_retry_limit        = 0     # pipeline handles retries explicitly

  # Triggered on demand by the nightly GitHub Actions workflow
  # (az containerapp job start), not on an ACA-internal schedule.
  manual_trigger_config {
    parallelism              = 1 # one run at a time — enforces the nightly lock
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aca.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.aca.id
  }

  dynamic "secret" {
    for_each = local.common_secrets
    content {
      name                = secret.value.secret
      key_vault_secret_id = secret.value.kv
      identity            = azurerm_user_assigned_identity.aca.id
    }
  }

  template {
    container {
      name    = "migration"
      image   = var.app_image
      cpu     = 2.0
      memory  = "4Gi"
      command = ["bin/migrate", "all"]

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.common_secrets
        content {
          name        = env.value.env
          secret_name = env.value.secret
        }
      }
    }
  }
}
