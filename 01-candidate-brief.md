# DevOps Engineer — Take-Home Exercise

**Time budget:** ~1-2 hours. We respect your time — please don't exceed this. We're far
more interested in your *judgment and trade-off thinking* than in polish or completeness. Using AI tools is completely acceptable but it is expected that anything you submit is reviewed and endorsed by you and that you can discuss any aspect of it during the interview.

**Format:** A short design document **plus one small working artifact** (your choice — see
below). No live cloud account or running deployment is required.

**What we're hiring for:** an engineer who will own the cloud deployment of our new platform
and, most importantly, build the **automated overnight pipeline that keeps it in sync with our
legacy system** during a parallel-run period before cutover.

---

## The Situation

We are replacing a legacy case-management platform with a new web application. During the
transition, **the legacy system stays the live system of record.** The new application runs
alongside it so stakeholders and QA can validate the new product against realistic, *near-current*
data.

To make that possible, **every night** we need to refresh the new application's database with the
latest legacy data. A migration engine that performs the actual data transformation **already
exists and is written** — your job is **not** to write migration logic. Your job is to design and
automate the *pipeline and infrastructure* that runs it reliably, every night, in the cloud.

### The two systems

| | Legacy (source) | New (target) |
|---|---|---|
| Stack | .NET + Angular | Ruby on Rails 8 (Hotwire) |
| Database | **Microsoft SQL Server** (port 1433) | **PostgreSQL 17** |
| Cache / jobs | — | **Redis** + **Sidekiq** background workers |
| Role during transition | Live production, read-only to us | Validation / pre-production |
| Containerized? | n/a (we only read its data) | Yes — a production `Dockerfile` exists |

### The migration engine (already built — treat as a black box)

- Invoked as a single command inside the app container: **`bin/migrate all`**.
- **Reads** the legacy SQL Server via environment variables:
  `OV_DB_HOST`, `OV_DB_PORT` (1433), `OV_DB_NAME`, `OV_DB_USERNAME`, `OV_DB_PASSWORD`.
- **Writes** to the new PostgreSQL database via `DATABASE_URL`.
- **Idempotent / re-runnable:** it truncates the target tables up front, so a fresh run always
  produces a clean, complete copy. A half-finished run can simply be run again.
- **Long-running:** a full run moves a large dataset and takes **roughly 4–8 hours**. An optional
  audit-log phase alone is **~335 million rows** and adds several hours.
- **Resilient by design:** it already has some rudimentary retry logic and tolerates transient source-DB
  blips, but it expects the SQL Server source to be *reachable and stable* for the duration.
- It tracks its own progress/state and prints progress as it goes.

### The application runtime (the thing you'll deploy)

- A **web** process (Puma) and one or more **worker** processes (Sidekiq).
- Needs **PostgreSQL** and **Redis** (three logical Redis DBs: cable, cache, sidekiq).
- **The app uses WebSockets** (real-time UI updates over a persistent connection, backed by the
  Redis "cable" channel). Whatever fronts the web tier must support WebSocket upgrades and
  long-lived connections, and you should think about what happens to open connections during
  deploys/restarts.
- All configuration/secrets supplied via environment variables.
- The container image already bundles the SQL Server client libraries needed by the migration.

### Scale & shape (size your design to this — it's not "web scale")

- **Users:** ~170 internal/employee users (daily, active) plus roughly double that in external
  client users who log in less frequently. Call it a few hundred users, low-hundreds concurrent
  at peak — modest, but with real-time WebSocket connections held open.
- **Database:** the new PostgreSQL database is **~100 GB**. That size matters for migration
  runtime, backup/restore times, and especially for anything that copies the DB (see the
  dynamic-staging stretch goal).
- Right-size accordingly — we're not looking for a 50-node cluster, and over-provisioning is a
  cost (and judgment) signal too.

### Constraints & context

- **Target cloud: Microsoft Azure.** Choose the specific Azure services yourself and justify them.
- The **legacy SQL Server is live production** — your pipeline must get the data it needs
  **without putting load on or risking** that production database.
- The nightly run **must finish overnight** (assume a window of roughly 8 hours) and must alert
  someone when it fails.
- Today the new app deploys via a simple GitHub Actions → managed-host flow. You're free to
  propose something different for Azure.

---

## What to Deliver

### 1. A design document (~2–3 pages, bullet points are fine)

Cover, at minimum:

1. **Target Azure architecture** — what runs where. How you'd host the Rails web + Sidekiq
   worker processes, PostgreSQL, and Redis. Name the Azure services and say *why*.
2. **The nightly migration pipeline** — this is the centerpiece. Walk through the sequence end
   to end:
   - How you obtain the legacy SQL Server data **safely** (without loading the live production DB)
     and make it available to the migration engine.
   - **Where and how** the multi-hour `bin/migrate all` run actually executes (what compute,
     how it's triggered, how it's prevented from being killed mid-run).
   - How you handle the **long runtime, failures, retries, and re-runs** so a bad night doesn't
     leave the new app serving broken/partial data.
   - How the freshly-migrated database becomes the one the live app serves (cut-in / swap), and
     how you'd **roll back**.
   - **Secrets, networking, validation/smoke checks, alerting, and cost** considerations.
3. **Path to cutover** — briefly: how this nightly *sync* eventually becomes the real one-time
   *go-live cutover*. What changes?
4. **Risks & open questions** — what you'd want to confirm with us, and what could go wrong.

### 2. One small working artifact (your choice)

Pick the *any* that best showcases your strengths. It does **not** need to run end-to-end — we'll
read it for realism and good practice, not execute it:

- A **CI/CD pipeline definition** (GitHub Actions or Azure Pipelines YAML) for the nightly job.
- An **Infrastructure-as-Code module** (Bicep or Terraform) provisioning part of the Azure target.
- An **orchestration script** (e.g. shell) that sequences backup → migrate → validate → promote.
- A **Dockerfile / compose** (or container-job spec) tailored to running the migration.

Add a few inline comments or a short README note explaining the choices you made and what you'd
build out next given more time.

### Stretch / optional (don't spend long here — we'll discuss it live)

Later, we want **dynamic staging environments** — an ephemeral, isolated environment spun up
per feature branch / pull request and torn down when it merges. You don't need to build this.
Just jot down **a few bullets** on how you'd approach it on Azure and where the hard parts are —
in particular, **how each ephemeral env gets a database** when the real one is ~100 GB (a full
re-migration per PR is far too slow), and how the WebSocket app behaves behind per-env routing.
We'll dig into it together in the interview.

---

## Ground Rules

- **Out of scope:** writing or changing the migration logic itself, and any application feature
  code. Assume both work.
- Use any tools, docs, or AI assistants you like — just be ready to **explain and defend every
  decision** live. We'll go deep on your reasoning, so design things you actually understand.
- If something is ambiguous, **state your assumption and move on.** Documenting assumptions is
  part of the exercise.
- There is no single right answer. A focused, well-reasoned 2-page submission beats an
  exhaustive one.

## How to Submit

Send us your design document and your artifact (a link to a small repo/gist, or attachments) at
least an hour before the interview (the earlier the better though) so we can read it beforehand. Come ready to walk us through it.
