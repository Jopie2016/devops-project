# Nightly Legacy → New-Platform Sync — Azure Design

**Author:** Jodi Pierre-Louis
**Scope:** Cloud deployment of the new Rails platform + the automated overnight pipeline that keeps it in sync with the legacy SQL Server during the parallel-run period.

---

## Guiding principles (the lens I designed through)

1. **Protect the legacy production database above all else.** It is the live system of record. The pipeline never reads from it directly.
2. **Never serve broken or partial data.** Because `bin/migrate all` truncates target tables up front, a failed run must never touch the database the app is actively serving. This is the design's centerpiece — it's really a **blue/green database swap** problem.
3. **Right-size for ~300 users / low-hundreds concurrent.** Modest scale. Over-provisioning is a cost and judgment signal, so I deliberately avoid Kubernetes-scale infrastructure.
4. **Rollback must be a config flip, not a data recovery.**

---

## 1. Target Azure Architecture

| Concern | Azure service | Why |
|---|---|---|
| Rails web (Puma) + Sidekiq workers | **Azure Container Apps (ACA)** | Serverless containers from one image; native **WebSocket** upgrade + long-lived connection support; independent scale rules per process; **ACA Jobs** give me the long-running migration executor on the same platform. Right-sized — no cluster to operate. |
| Long migration run | **ACA Job** (same image) | Run-to-completion, **no HTTP/runner timeout**, scales independently of the serving tier. |
| Primary database | **Azure Database for PostgreSQL Flexible Server 17** | Managed, HA standby, fast PITR, read replicas if needed. Hosts the **blue/green** databases. |
| Cache / jobs | **Azure Cache for Redis** | Three logical DBs — cable (0), cache (1), sidekiq (2). |
| Secrets | **Azure Key Vault** | All credentials injected as ACA secret refs — nothing baked into the image. |
| Networking | **VNet + private endpoints** | Postgres, Redis, and the ephemeral SQL copy are private-only. No public database surface. |
| Image registry | **Azure Container Registry (ACR)** | Same image feeds web, worker, and the migration job. |
| Observability / alerting | **Azure Monitor + Log Analytics + Action Group** | Job-failure and window-overrun alerts to email/Teams. |

**Why ACA over AKS / App Service:** AKS is operationally heavy for a few hundred users — the brief explicitly warns against a 50-node mindset. App Service handles the web tier but is awkward for long-running Sidekiq workers and the multi-hour migration. ACA covers **all three workloads** (web, worker, job) on one platform with the least operational surface. This mirrors the VM→container consolidation I did at Anata.

**WebSocket handling:** ACA ingress supports WS upgrades and long-lived connections natively. On any deploy or promotion I do a **rolling restart** so instances bounce one at a time; ActionCable clients auto-reconnect, and the disruption lands in the overnight window regardless.

---

## 2. The Nightly Migration Pipeline (centerpiece)

**Orchestrator/executor split — the key decision.** GitHub Actions is the **scheduler and orchestrator brain**; the **ACA Job is the heavy executor**. I do *not* run `bin/migrate all` inside a GitHub-hosted runner because runners cap at 6 hours and the migration runs 4–8 (up to 12+ with audit logs). The trigger and the short promote/validate steps use a standard GitHub-hosted runner. The poll-for-completion step — which must outlast 6h — runs on a **self-hosted runner** (no time limit). The multi-hour execution itself lives in the ACA Job where nothing can kill it mid-run.

### Step 1 — Obtain legacy data safely (no load on prod)
- **Assumption (stated):** the legacy team takes regular full backups we can access.
- Copy the latest backup to **Azure Blob Storage**, restore it into an **ephemeral Azure SQL Managed Instance** spun up at pipeline start.
- The migration reads from this **restored copy**, never from live production. Zero query load and zero risk to the system of record.
- *Alternative considered:* transactional replication / read replica — rejected for the parallel-run period because it requires changes and ongoing load on the production server. Backup-restore is the lower-risk ask of the legacy DBA.

### Step 2 — Run the migration where it can't be killed
- **ACA Job** triggered nightly (~22:00, targeting completion well inside the ~8h window).
- Runs `bin/migrate all` with `OV_DB_*` pointed at the ephemeral SQL MI and `DATABASE_URL` pointed at the **idle** database (green if the app is serving blue, and vice-versa).
- **Concurrency lock:** two layers prevent overlapping runs — a GitHub Actions `concurrency` group (only one workflow run active at a time) and `parallelism: 1` on the ACA Job itself (only one execution replica allowed). Together they guarantee a second night can't start while the first is still running.
- **Long runtime / retries / re-runs:** the engine is idempotent (truncate-and-rewrite) and tracks its own progress, so a failed or half-finished run is simply re-run. The ACA Job has a generous replica timeout that exceeds worst-case runtime, and inherits the engine's own transient-blip retries.

### Step 3 — Validate before promoting
- Post-migration **smoke checks** against the idle DB over a direct `psql` connection (no app boot required):
  - **Row counts** on key tables (`cases`, `users`, `documents`) must exceed a known minimum threshold.
  - **Schema integrity:** `schema_migrations` must be non-empty — a truncated run leaves it missing or empty.
  - **Connectivity:** a `SELECT current_database(), now()` confirms the DB is accepting connections.
- **If any check fails → alert and stop.** The app keeps serving last night's good data on the *other* database. Nothing partial is ever exposed.

### Step 4 — Promote (cut-in / swap)
- Update the `DATABASE_URL` secret in **Key Vault** to point at the freshly migrated DB.
- **Rolling restart** of the web + worker ACA apps so the new connection string takes effect while draining WebSocket connections gracefully.
- Blue/green **alternates each night** — tonight's target becomes tomorrow's live DB.

### Step 5 — Teardown
- Destroy the ephemeral SQL MI. **Cost is bounded to the migration window only.**

### Rollback
- Repoint `DATABASE_URL` back to the prior database and roll the apps. **Instant, no data recovery** — the previous good copy is untouched on the other database. This is the entire payoff of the blue/green model.

### Cross-cutting
- **Secrets:** Key Vault → ACA secret refs (legacy creds, `DATABASE_URL`, Redis URL, app keys). Never in the image.
- **Networking:** everything reachable only over the VNet via private endpoints.
- **Alerting:** Azure Monitor fires on **job failure** *and* on **early overrun warning** (migration still emitting logs after 6h — while time remains in the ~8h window to act, page someone, or skip the audit-log phase).
- **Cost:** ACA scales the serving tier to demand; the migration job and the SQL MI exist only during the window; Postgres is right-sized with HA. No idle large compute.

---

## 3. Path to Cutover

The nightly sync **is the cutover rehearsal** — by go-live we'll have run it dozens of times.

- At go-live, **quiesce the legacy system** (put it read-only) for one final consistent snapshot.
- Run the migration one last time and promote as on any normal night.
- **Stop the nightly ACA Job** and decommission the SQL-restore infrastructure.
- Flip DNS / authentication fully to the new app; the legacy system retires.
- The **blue/green database pattern stays** as a standard deploy safety net post-cutover.

What actually changes is small: the trigger goes from "every night" to "once, on a quiesced source," and the legacy-copy plumbing is removed. The promotion mechanics are identical — which is exactly why nightly rehearsal de-risks the real event.

---

## 4. Risks & Open Questions

- **Backup access & format.** I assume we get a backup copy to Blob. Need to confirm format (native `.bak` vs `.bacpac`), size, and the transfer window — it gates Step 1.
- **SQL MI restore time on ~100 GB.** Restoring the legacy backup adds perhaps 1–2 hours to the window. Need to validate the full sequence still lands inside ~8 hours; if tight, pre-stage the restore earlier in the evening.
- **Audit-log phase (~335M rows).** This can push runtime past 12 hours — beyond the window. I'd propose **excluding the audit phase during the parallel-run period** and only including it at final cutover, pending confirmation it isn't needed for validation.
- **WebSocket reconnect behavior.** ActionCable auto-reconnects, but I'd confirm with the app team that a brief reconnect during the overnight promotion is acceptable (it should be).
- **SQL MI cost.** Managed Instance is pricey even when ephemeral. I'd evaluate **SQL Server on an ephemeral VM** as a cheaper restore target since it only lives during the window — a cost/complexity trade-off to settle with the team.
- **Promotion atomicity.** A Key Vault secret swap + rolling restart isn't instantaneous across replicas; I'd confirm the brief seconds of mixed-revision state during a rolling restart are acceptable (no cross-DB writes occur, so it's safe — worth stating explicitly).

---

## Stretch — Dynamic per-PR staging environments (brief notes)

The hard part is giving each ephemeral environment a **~100 GB database** without a full re-migration per PR (far too slow).

- **Copy-on-write clones** from a nightly Green snapshot — fast, cheap, near-instant per PR. Best fit.
- Postgres **branching** (Neon-style) if we're open to it, or storage-level snapshot restores on Flexible Server.
- **Routing:** per-PR subdomain via ACA ingress; each env gets its own **Redis namespace / ActionCable channel prefix** so WebSocket connections never cross environments.
- Teardown on merge/close reclaims the clone and the env.
