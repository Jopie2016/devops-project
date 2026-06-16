output "web_app_fqdn" {
  description = "Public FQDN of the Rails web app."
  value       = azurerm_container_app.web.ingress[0].fqdn
}

output "acr_login_server" {
  description = "ACR login server — use in CI to push images."
  value       = azurerm_container_registry.main.login_server
}

output "migration_job_name" {
  description = "ACA Job name — pass to 'az containerapp job start' in the nightly workflow."
  value       = azurerm_container_app_job.migration.name
}

output "key_vault_uri" {
  description = "Key Vault URI — reference secrets here from the nightly promotion script."
  value       = azurerm_key_vault.main.vault_uri
}

output "postgres_fqdn" {
  description = "PostgreSQL Flexible Server FQDN (private)."
  value       = azurerm_postgresql_flexible_server.main.fqdn
  sensitive   = true
}

output "active_database" {
  description = "Currently active blue/green slot being served."
  value       = var.active_db
}
