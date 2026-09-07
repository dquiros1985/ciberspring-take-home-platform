# DevOps and Platform Ownership Exercise — Response

**From:** David Quirós
**Time spent:** ~90 minutes on this write-up. Behind it is a hands-on build of the described stack (roughly a day across several sessions) — I wanted the numbers below to be measured, not assumed. Details in `VALIDATION-LOG.md`.

A note on method: rather than reason about this purely on paper, I stood up a working version of the described stack — dev, staging, and production Postgres via Terraform, a role model, a Vercel deployment, pgvector with a real index — and tested the claims below directly. Where I give a number or say something "fails," that's measured.

**Assumptions I'm making** (stated up front, resolvable in a first conversation):

- n8n is self-hosted (Azure Container Apps or a VM in the same region), not n8n Cloud. If it's Cloud, the private-network options in section 2 change for the pipeline as well.
- Documents ingested for the life-sciences clients may contain regulated data. I treat everything reaching Postgres and the LLM as sensitive until told otherwise.
- Nothing in the described stack generates embeddings — Claude has no embeddings endpoint (see section 1).
- The team is small and there is no dedicated DevOps function; the promotion model below is sized for that, not for a 50-engineer org.

---

## 1. Database ownership

**Role and credential isolation across dev/staging/production**

- One Postgres Flexible Server per environment, each in its own resource group. No shared server, no schema-by-convention separation — actual separate instances with separate blast radius.
- Four identities per environment, same shape everywhere: `pgadmin` (the server administrator, used only for provisioning and migrations), `app_rw` (the application's normal read/write role), `app_ro` (read-only — reporting, health checks), `n8n_ingest` (scoped to the ingestion pipeline's write path only).
- `REVOKE ALL ON DATABASE ... FROM PUBLIC` and `REVOKE ALL ON SCHEMA public FROM PUBLIC`, then explicit grants on an `app` schema only. `ALTER DEFAULT PRIVILEGES` so every *new* table automatically inherits the right grants for `app_rw`/`app_ro` — least privilege doesn't depend on someone remembering to grant it on the next table. I verified the inheritance: a table created later showed `app_rw=arwd, app_ro=r` with zero explicit grants.
- Every credential is generated randomly and written to a secrets manager under a per-environment path. Nothing is hardcoded and nothing lives in a `.env` file. Where the app platform needs a value (Vercel's `DATABASE_URL`), it goes in as a *Sensitive* environment variable scoped to that one Vercel environment — write-only after creation, not readable back from the dashboard or CLI.
- Transport: `require_secure_transport` stays ON (the Flexible Server default) — every client, including n8n and Vercel, connects with `sslmode=require`; nothing plaintext reaches the server.
- **I verified isolation directly, not just designed it**: I took dev's `app_rw` password and tried it against production. Postgres rejected it (`FATAL: password authentication failed`). The same credential scoped to production worked as a control. A leaked dev credential opens nothing in prod — enforced by Postgres itself, not by naming discipline.

**Audit trail (you said you audit every action)**

- `pgaudit` enabled with `pgaudit.log = DDL, ROLE, WRITE`, plus `pg_stat_statements`. Every schema change, role change and write is logged with the role that ran it — which is only meaningful because the roles above are narrow: the log tells you what the pipeline was *allowed* to do, not just what it did.
- Those logs should leave the server: Azure diagnostic settings → Log Analytics for querying, plus an immutable Storage account for the retention period your policy defines. An auditor will ask for a sample and the retention setting, not the policy sentence.

**Backups and restore verification**

- Two layers: the platform's automated backups (retention scaled by environment — short for dev/staging; 35 days for production, which is Azure's maximum and should match the written retention policy the auditor will ask to see; geo-redundant on production, which can only be set at creation), plus a scheduled logical `pg_dump` (schema + custom-format) written to storage outside the database service. Platform backups disappear if the server is deleted; a logical dump doesn't.
- "We have backups" is not the same claim as "we can restore." I did a live restore drill: planted two timestamped markers, point-in-time restored to a fresh disposable server between them, confirmed marker-1 was present and marker-2 absent, compared checksums, then deleted the restore server. Measured time-to-usable for a 32 GiB Burstable server: ~9 minutes. This should be a scheduled quarterly exercise with the output kept as evidence — a backup nobody has restored is a hope, not a control.

**pgvector operational considerations**

This is the section with the most concrete findings, because the numbers surprised me:

- pgvector is a normal extension operationally, but similarity search only scales with an index. Without one, a nearest-neighbor query over 20,000 rows took **~216 ms** (sequential scan). With an HNSW index, the same query dropped to **~5.5 ms** — about 39x.
- Building that index is not free. On a small (Burstable) instance it took **~47 seconds** for only 20,000 rows of 1536-dimension vectors, and required raising `maintenance_work_mem` well above the tier's ~97 MB default. At real data volumes, index builds belong in a scheduled maintenance window, not a background afterthought during a deploy.
- The index itself was **over 100x the size of the table it indexes** (156 MB index vs. 1.3 MB of data). That's a real capacity-planning input — vector index storage needs to be sized deliberately as the corpus grows.
- Built-in connection pooling (PgBouncer) is **not available on the Burstable tier** — confirmed directly against a live server (`ServerConfigurationNotAllowed`), not from documentation. Given Vercel functions and n8n both make short-lived connections, production sizing needs to account for this explicitly: General Purpose tier (which supports it) or an external pooler.
- Extension versions (`vector`, `pgaudit`) are tracked as upgrade items; re-embedding at scale needs periodic `VACUUM` to manage bloat.
- Stated assumption: nothing in this stack generates embeddings — Claude doesn't expose an embeddings endpoint. A production RAG pipeline needs a separate embedding provider (Voyage AI, Azure OpenAI, or self-hosted) with its own credentials, data-handling terms and cost line. I'm flagging that as an explicit dependency rather than a detail to skip.

---

## 2. Getting to production

**Standing it up**

- Provision via Terraform, not manual clicks or ad hoc CLI commands. I built staging and production as the *same reusable module*, with only a per-environment `.tfvars` file differing — SKU, backup retention, geo-redundancy. The diff between the staging and production `.tfvars` files **is** the environment policy: reviewable in a pull request, not something that lives in someone's head. (In the lab build the production `.tfvars` carries the real recommendation commented next to a cost-safe value; the real one is General Purpose, 35-day retention, geo-redundant.)
- `terraform plan` before every `apply`, no exceptions — plan is the reviewable diff; apply is a separate, deliberate step from a saved plan.
- **Change management from day one, not "later":** production applies happen only from CI on a merged, reviewed pull request — never from a laptop. That single rule is also the SOC 2 change-management control (who changed what, approved by whom, when) and it costs a few hours to set up. In the lab I applied from a local shell, which is exactly the thing this rule exists to stop.
- Schema changes go into versioned, ordered SQL files applied identically per environment by the same pipeline. I hit the alternative failure mode directly: a health-check endpoint querying a table that existed on dev — because I'd created it there ad hoc — but nowhere else, because it was never in the versioned migration. That's exactly the drift a "two environments today, both manually provisioned" setup produces, and it's silent until something breaks in the environment that doesn't have it.

**Promoting safely**

- The application itself is environment-agnostic — only its configuration (database URL, API keys) changes per environment. Code is identical across dev/staging/prod.
- Rollback means "promote the previous, already-built deployment," not "revert code and rebuild." That's a property of the deployment platform (Vercel's immutable deployments support this natively) — it shouldn't need custom tooling.
- **The finding that matters most here**: I tested what happens when you "promote" the app to point at a real, freshly-built production database, expecting connectivity to just work. It didn't. Same failure as dev — a ~8.5-second timeout (the Azure firewall drops the packets; there's no refusal to see) — because production has the *same* public-IP-allowlist firewall model as every other environment, and Vercel functions have no stable egress IP. Promotion alone does not fix this; adding one more firewall rule per environment is not a production posture, it's a slightly larger version of the current problem.
- The fix is architectural, and it's worth being precise because Vercel cannot join an Azure VNet or consume a Private Endpoint. The realistic options are:
  1. **Keep Vercel, give it a fixed identity**: Vercel Secure Compute (dedicated static egress IPs, Enterprise) and allow only those IPs on the Flexible Server, with public access otherwise disabled. Cheapest change to the current architecture.
  2. **Keep Vercel, put a door in Azure**: a small API layer inside the VNet (Container Apps / App Service with VNet integration) that is the *only* thing talking to Postgres over Private Link, exposed to Vercel behind authenticated ingress (Front Door / App Gateway). More moving parts, but the database is never on the public internet.
  3. **Move the app into Azure** (Container Apps or App Service) if the regulated clients make "database never publicly reachable" a hard requirement. Loses Vercel's ergonomics; gains a single network boundary and a simpler audit story.
  n8n, being self-hosted in Azure, uses Private Link in all three cases. I'd bring this decision to the team before any production traffic, because it also decides where the app's compliance boundary sits.
- One more concrete prerequisite I hit directly: branch-based staging previews (a Preview deployment scoped to a `staging` branch) require the Vercel project to be connected to a Git repository. A CLI-only deploy — reasonable for getting moving — doesn't get that until the Git connection exists. Small fix, but it has to happen before staging is used as a real promotion gate.
- Go-live sequence I'd follow: production infra applied from CI → migrations applied → smoke test of `/api/health` and one real retrieval query against prod → DNS/production alias switched → first nightly n8n run observed end to end → written go/no-go with the checklist kept as evidence.

---

## 3. My read on the current setup

**What I'd keep**

- Vercel + Next.js for the app layer. For a small team with no dedicated DevOps function, a managed serverless platform is the right tradeoff — low operational overhead, and nothing here suggests you've outgrown it. The network question above is real, but it's solvable without leaving the platform.
- pgvector inside Postgres rather than a standalone vector database. One fewer system to run, secure, patch and audit — and once properly indexed, the performance story holds up at this scale.
- Azure Postgres Flexible Server as the managed database. No reason to self-host Postgres here.
- n8n for nightly ingestion — with conditions: pinned version, running inside the Azure VNet, connecting as `n8n_ingest` only, and its `N8N_ENCRYPTION_KEY` (which protects every credential n8n stores) treated as a first-class secret in the same manager as everything else.
- Claude via the API — with the data-handling side made explicit (next section).

**What I'd change before production, in rough priority order**

1. **The public-IP-allowlist database access model.** The biggest blocker, and measured against a real production database, not inferred. Pick one of the three options in section 2 before real traffic flows; it affects Vercel and n8n's nightly connection alike, and it decides where the compliance boundary sits.
2. **Manual provisioning of dev and staging.** Move to Infrastructure as Code now, before a third environment makes drift worse. I hit real drift during this exercise from exactly this kind of ad hoc setup — small-scale proof of a problem that gets expensive at real scale.
3. **Production changes only through reviewed CI.** Cheap, and it is the change-management control an auditor will trace first.
4. **No described credential isolation.** Add the role model above — it took under an hour to build, and it's the difference between "a leaked dev credential is annoying" and "a leaked dev credential is a production incident."
5. **No described backup verification.** "We take backups" without a tested restore is a common audit gap; you said you're working toward SOC 2, and this is exactly the control an auditor asks to see evidence for, not a policy statement.
6. **n8n's pipeline credential scope.** Nightly ingestion should run under a role that can write to its ingestion path and nothing else — not an admin credential. Given you audit every action, a narrowly scoped pipeline identity is what makes that audit trail mean something.
7. **The LLM data path.** "Claude as our LLM" plus regulated clients means three things need to be written down before production: (a) which data classes are allowed to reach the model at all (de-identified only, or with the appropriate agreement in place), (b) the API terms in use — enterprise/zero-data-retention, no training on inputs — attached to the vendor file the auditor will request, and (c) every prompt and response logged with a correlation ID alongside the pgaudit trail, so "audit every action" covers the model calls, not only the database.
8. **Connection pooling.** Confirmed unavailable on the current tier — needs an explicit decision (tier upgrade or external pooler) before Vercel + n8n connection volume becomes a production problem, rather than being discovered under load.
9. **Git-connect the Vercel project.** Needed for branch-based staging promotion and review-before-merge, not just fast CLI deploys.

**What I'd cover next, given more time**

- Observability: diagnostic settings wired to alerting (query performance regressions, connection saturation, failed audit-log delivery). The pgaudit logging itself is in place; the alerting on it is not.
- Passwordless / Entra ID authentication for the humans who need direct database access, instead of long-lived passwords.
- Live-testing the rollback path (two distinct deployments, roll back between them) — stated above as a platform property, not something I exercised in this build.
- Running the actual n8n pipeline against the `n8n_ingest` role; in this build the role and its grants exist and were tested with direct SQL, but not from a live n8n job.

---

*Happy to walk through any of this live, including the working build.*
