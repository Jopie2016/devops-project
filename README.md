# OV DevOps Take-Home — Artifacts

**Author:** Jodi Pierre-Louis

## What's in here

| File | What it is |
|---|---|
| `01-candidate-brief.md` | Original exercise brief (unchanged) |
| `02-design-document.md` | Full design doc — architecture, pipeline, cutover, risks |
| `terraform/` | IaC for the Azure platform (VNet, ACA, Postgres blue/green, Redis, Key Vault, Monitor) |
| `.github/workflows/nightly-sync.yml` | The nightly pipeline — backup → migrate → validate → promote → teardown |

---

## Key design decisions (and why)

**Azure Container Apps over AKS.** The scale is ~300 users / low-hundreds concurrent. ACA covers all three workloads — web (Puma), worker (Sidekiq), and the migration job — on one platform with no cluster to operate. AKS would be over-engineering for this scale.

**Orchestrator/executor split in the pipeline.** GitHub-hosted runners cap at 6 hours. `bin/migrate all` runs 4–8+ hours. The workflow *triggers* an ACA Job and polls for completion; the multi-hour work runs inside ACA where nothing can kill it mid-run.

**Blue/green database swap (not blue/green servers).** Two logical databases (`app_blue`, `app_green`) on one PostgreSQL Flexible Server. The migration writes into the idle slot; after smoke checks pass, `DATABASE_URL` in Key Vault is updated and the apps get a rolling restart. Rollback = repoint the secret back to the prior slot and restart. No data recovery required.

**Ephemeral SQL MI for the legacy source.** The legacy SQL Server is live production — we never read from it directly. We restore its nightly backup into a temporary Azure SQL Managed Instance that exists only during the migration window, then tear it down. Zero load on prod; cost bounded to the window.

**Exclude the audit-log phase during parallel-run.** The 335M-row audit phase pushes runtime past 12 hours. The workflow exposes a `skip_audit_logs` parameter (default: true) so the overnight window is reliably met during validation. The full run is reserved for the final cutover migration.

---

## What I'd build out next given more time

1. **Terraform remote state** — wire up an Azure Storage backend with state locking before anyone else touches this.
2. **PR environment cloning** — snapshot last night's Green DB using Postgres Flexible Server PITR/snapshot and clone it per PR. No full re-migration needed (the dynamic staging stretch goal).
3. **OIDC auth for GitHub Actions** — replace the service principal secret with a federated OIDC identity so no long-lived credentials are stored in GitHub Secrets.
4. **Smoke check expansion** — the current row-count checks are a starting point. Real validation would compare counts to the previous run's baseline (stored in Blob or a small tracking table) and run a subset of application integration tests against the idle DB before promoting.
5. **Terraform for the ephemeral SQL MI** — the restore target is currently scripted in the workflow. A Terraform module with `count = var.migration_running ? 1 : 0` would make it reproducible and auditable.

---

## Required GitHub Secrets

| Secret | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | Federated/service principal client ID |
| `AZURE_TENANT_ID` | Azure AD tenant |
| `AZURE_SUBSCRIPTION_ID` | Subscription containing all resources |
| `LEGACY_SQL_MI_NAME` | Name of the Azure SQL MI hosting the restored legacy backup |
| `LEGACY_BACKUP_BLOB_URL` | Blob URL of the legacy nightly `.bak` file |

Remaining credentials (Postgres password, Redis key, Rails master key, legacy DB credentials) are stored in **Azure Key Vault** and injected into ACA at runtime — not in GitHub Secrets.