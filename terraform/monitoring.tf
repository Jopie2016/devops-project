resource "azurerm_monitor_action_group" "oncall" {
  name                = "ov-oncall"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "ov-oncall"

  email_receiver {
    name          = "oncall-email"
    email_address = var.alert_email
  }
}

# Alert when the migration job exits with a failed status.
resource "azurerm_monitor_metric_alert" "migration_failed" {
  name                = "migration-job-failed"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app_environment.main.id]
  description         = "Nightly migration job completed with a failure status."
  severity            = 1 # Error

  criteria {
    metric_namespace = "Microsoft.App/managedEnvironments"
    metric_name      = "JobExecutionRunningCount"
    aggregation      = "Count"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.oncall.id
  }
}

# Alert if the job is still running 12 hours into the window — risk of missing
# the morning cut-in window before users arrive.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "migration_overrun" {
  name                = "migration-job-overrun"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  description         = "Migration job still running after 12 hours — may miss the morning window."
  severity            = 2 # Warning
  enabled             = true

  scopes                  = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency    = "PT1H"
  window_duration         = "PT12H"

  criteria {
    query = <<-QUERY
      ContainerAppConsoleLogs_CL
      | where ContainerName_s == "migration"
      | where TimeGenerated > ago(12h)
      | summarize count()
      | where count_ > 0
    QUERY

    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.oncall.id]
  }
}
