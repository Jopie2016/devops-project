variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "environment" {
  description = "Deployment environment label (e.g. production, staging)."
  type        = string
  default     = "production"
}

variable "app_image" {
  description = "Fully-qualified container image for web, worker, and migration job (same image)."
  type        = string
  # e.g. ovacr.azurecr.io/app:latest
}

variable "active_db" {
  description = "Which blue/green slot the app currently serves. Alternates each nightly run."
  type        = string
  default     = "blue"
  validation {
    condition     = contains(["blue", "green"], var.active_db)
    error_message = "active_db must be 'blue' or 'green'."
  }
}

# Legacy SQL Server credentials — injected at plan time from CI secrets,
# never stored in source control.
variable "legacy_db_host" {
  type      = string
  sensitive = true
}

variable "legacy_db_name" {
  type      = string
  sensitive = true
}

variable "legacy_db_username" {
  type      = string
  sensitive = true
}

variable "legacy_db_password" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  description = "Email address for Azure Monitor job-failure and overrun alerts."
  type        = string
}

variable "rails_master_key" {
  description = "Rails RAILS_MASTER_KEY for credentials decryption."
  type        = string
  sensitive   = true
}
