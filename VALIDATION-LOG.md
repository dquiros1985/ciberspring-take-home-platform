# Ciberspring Take-Home Lab — Validation Log

## Canonical names (Phase 0, confirmed 2026-09-06/07)
| Key | Value |
|---|---|
| LOC | centralus |
| SUFFIX | 0a99 |
| MYIP | <REDACTED_HOME_IP> |
| RG_DEV / RG_STG / RG_PROD | rg-ciplat-dev / rg-ciplat-stg / rg-ciplat-prod |
| PG_DEV / PG_STG / PG_PROD | pg-ciplat-dev-0a99 / pg-ciplat-stg-0a99 / pg-ciplat-prod-0a99 |
| DB name | ciplat |
| Roles | pgadmin, app_rw, app_ro, n8n_ingest |
| Vault paths | homelab/infra/ciplat-dev, -stg, -prod |
| Vercel project | ciplat-web |

## Phase 0 — Preflight and mental model
| # | Step | Command (short) | Evidence (literal, <=3 lines) | Result | Key Takeaway |
|---|------|-----------------|-------------------------------|--------|--------------|
| 0.1 | Vault login + load env | `vault login -method=userpass`; `source vault-project-env.sh` | fresh login failed (connection refused, VAULT_ADDR unset at call time); cached token still valid: display_name=userpass-david, ttl=2760008s | OK-with-note | "I keep every environment credential in a secrets manager and load it into the shell session on demand, never in a config file or shell history." |
| 0.2 | Tooling census | `az/psql/node/vercel/terraform/docker/vault --version` | az 2.90.0, psql 18.6 (installed), node v26.5.0, vercel 59.11.7 (installed), terraform 1.15.8, docker daemon not running, vault 2.0.4 | OK | n/a |
| 0.3 | Azure auth | `az login --service-principal --username ... --password=... --tenant ...` | FIRST ATTEMPT FAILED: `--client-secret` flag not recognized by az 2.90.0; RETRY with verified `--password=` flag succeeded: subscription "Azure subscription 1", State=Enabled | OK | n/a |
| 0.4 | Region + SKU check | `az postgres flexible-server list-skus -l centralus` | Standard_B1ms Burstable 1 2GiB listed in centralus; eastus2 returned no Burstable rows | OK | n/a |
| 0.5 | Public IP | `curl https://api.ipify.org` | <REDACTED_HOME_IP> | OK | n/a |
| 0.6 | Canonical table filled | n/a | see table above | OK | n/a |

### Technical Notes
- az CLI 2.90.0 rejects `--client-secret` for `az login --service-principal`; correct flags are `--username`/`--password=` (or `--password` positional). ALWAYS read `az login --help` output in full before running.
- Never pass a secret as a bare CLI arg without first confirming the flag name from --help in a separate, prior step.
- Vault CLI token cache (`~/.vault-token`) is a file shared across all shells for the same OS user.

## Phase 1 — The dev database, by hand
| # | Step | Command (short) | Evidence (literal, <=3 lines) | Result | Key Takeaway |
|---|------|-----------------|-------------------------------|--------|--------------|
| 1.1 | Create RG | `az group create rg-ciplat-dev` | Location=centralus, Name=rg-ciplat-dev | OK | "Each environment lives in its own resource group, so blast radius from a mistake in one environment cannot reach another, and teardown is a single atomic operation." |
| 1.2 | Admin password to Vault | `vault kv put homelab/infra/ciplat-dev pgadmin=...` | version=1 | OK | "I keep every environment credential in a secrets manager..." |
| 1.3 | Create server | `az postgres flexible-server create ...` | state Ready, version 17, sku Standard_B1ms, storage 32GiB, backup retention 7d geo-Disabled | OK | n/a |
| 1.4 | Inspect | `show`, `firewall-rule list` | state=Ready; firewall rule for <REDACTED_HOME_IP> confirmed | OK | n/a |
| 1.5 | Extensions allowlist + restart | `parameter set azure.extensions/shared_preload_libraries`, `restart` | azure.extensions=vector,pgaudit,pg_stat_statements; shared_preload_libraries=pg_cron,pg_stat_statements,pgaudit | OK | "Static parameters like shared_preload_libraries require a restart, which is a maintenance window in production." |
| 1.6 | Create DB + extensions | `CREATE DATABASE ciplat`, `CREATE EXTENSION vector/pgaudit/pg_stat_statements` | \dx shows vector 0.8.2, pgaudit 16.0, pg_stat_statements 1.11 | OK | n/a |
| 1.7 | Role model | sql/roles.sql via psql -v from Vault | \du shows app_rw/app_ro/n8n_ingest (no superuser attrs); \dp app.documents shows exact grants per role | OK | "One Flexible Server per environment gives hard isolation; inside each, the application, ingestion pipeline and read-only consumers get distinct roles with grants limited to their schema..." |
| 1.8 | Prove the fence | app_ro INSERT, n8n_ingest SELECT, n8n_ingest INSERT | `ERROR: permission denied for table documents` (x2, literal), then `INSERT 0 1` | OK | "Least privilege is enforced at the database level, not just assumed: a read-only consumer cannot write, and the ingestion role cannot read what it writes." |
| 1.9 | Audit logging | `parameter set pgaudit.log=DDL,ROLE,WRITE` | confirmed value DDL,ROLE,WRITE; server-logs list still empty (propagation delay) | OK | "Every DDL, role and write statement is captured by pgaudit; the concrete log line is pending Azure's log propagation." |

### Technical Notes
- `az postgres flexible-server firewall-rule list` and `server-logs list` use `--server-name`/`-s`, NOT `-n` (unlike `create`/`show`/`restart` which take `-n`). Inconsistent across subcommands — always check `--help` per subcommand.
- Redirecting output to a temp file and `cat`-ing it, rather than letting psql write directly to the terminal, avoids PTY process termination issues on macOS when a command returns a non-zero exit (e.g., permission-denied).

## Phase 2 — Reconciliation & Restore Testing
| # | Step | Command (short) | Evidence (literal) | Result | Key Takeaway |
|---|------|-----------------|--------------------|--------|--------------|
| R.1 | Real Azure state | `az postgres flexible-server list -o table` | pg-ciplat-dev-0a99 (created 00:33:15Z) and pg-ciplat-dev-rst-0a99 (created 00:56:55Z), both Ready, B1ms, PG17, centralus; RG rg-ciplat-dev only | OK | n/a |
| R.2 | Vault versions | `vault kv metadata get homelab/infra/ciplat-dev` (fields only) | v1 [pgadmin] 00:32 · v2 [app_ro,app_rw,n8n_ingest,pgadmin] 00:45 · v3 [pgadmin] 01:05 (a `kv put` that DROPPED the three role passwords) | FIXED | "Use `vault kv patch` on an existing path; `put` replaces the whole secret." |
| R.3 | Which pgadmin works on dev | psql loop over v1/v2/v3 | dev: v3 OK (server was rotated), v1/v2 FAIL | OK | n/a |
| 2.2 | Markers already planted | `select * from app.documents` on dev | rows 1–3 n8n-test (00:47–00:49), 4 restore-drill marker-1 00:52:20Z, 5 marker-2 00:55:55Z | OK | n/a |
| 2.4 | Restore verification | firewall rule `myip` on rst, psql on rst with v1 password | rst auth OK with Vault v1; rst rows = 1..4, **marker-2 absent**; checksum rst `4|0bbda55d…` vs dev `5|8e775b07…` | OK | "I verify restores by planting a timestamped marker, restoring to a fresh server between two markers, and comparing a checksum: the copy must contain marker-1 and not marker-2." |
| R.4 | Measured RTO | rst created 00:56:55Z, earliestRestoreDate 01:05:21Z | ≈ 8.5 min until the restored server was usable | OK | "Measured RTO for a 32 GiB Burstable server PITR was ~9 minutes." |
| R.6 | Vault repaired | `vault kv patch … app_rw/app_ro/n8n_ingest` from v2 | now v4, fields [app_ro,app_rw,n8n_ingest,pgadmin]; app_ro authenticates on dev (`app_ro|5`) | OK | n/a |
| 2.6 | Delete restore server | `az postgres flexible-server delete -n pg-ciplat-dev-rst-0a99 --yes` | list now shows only pg-ciplat-dev-0a99 | OK | n/a |
| R.8 | Stale artifact removal | deleted `dev.plan` | module/pg-env kept for stg/prod in Phase 5 | OK | n/a |
| 2.5 | Logical backup (pg_dump) | `pg_dump --schema-only`; `pg_dump -Fc` | backups/ciplat-schema-20260907T014837Z.sql; backups/ciplat-full-20260907T014848Z.dump | OK | "I add a logical pg_dump to immutable storage for long-term retention and auditor requests, because platform backups are deleted with the server." |

## Phase 3 — pgvector, operationally
| # | Step | Command (short) | Evidence | Result | Key Takeaway |
|---|------|-----------------|----------|--------|--------------|
| 3.1 | Table + synthetic vectors | `CREATE TABLE app.chunks`; `INSERT ... generate_series(1,20000)` | INSERT 0 20000, Time: 9670.894 ms | OK | n/a |
| 3.2 | Baseline (no index) | `EXPLAIN ANALYZE ... ORDER BY embedding <=> ...` | Seq Scan on chunks, Execution Time: 216.513 ms | OK | n/a |
| 3.3 | HNSW index, timed | `SHOW maintenance_work_mem` (97MB) -> `SET 256MB` -> `CREATE INDEX CONCURRENTLY ... USING hnsw` | Time: 47276.927 ms (~47.3s) for 20k rows of vector(1536) | OK | "pgvector index builds are memory- and time-bound: on this Burstable SKU the default maintenance_work_mem was too small. On production data volumes this is a scheduled maintenance-window operation, not a background afterthought." |
| 3.4 | Re-run + size compare | same EXPLAIN ANALYZE; `pg_size_pretty` | Index Scan using chunks_embedding_hnsw, Execution Time: 5.517 ms (~39x faster); index_size=156 MB vs table_size=1336 kB | OK | "The HNSW index cut similarity queries from 216ms to 5.5ms, but the index itself is over 100x the size of the underlying data (156MB vs 1.3MB) -- index storage is a real capacity-planning input." |
| 3.5 | Ops checks | `pg_extension`; `pg_stat_statements`; `VACUUM VERBOSE` | vector 0.8.2, pgaudit 16.0, pg_stat_statements 1.11 all present; VACUUM: 20000 tuples, 0 dead | OK | "I track extension versions as an upgrade item, and monitor query performance via pg_stat_statements; re-embedding at scale needs periodic VACUUM to manage bloat." |
| 3.6 | Grants on new table | `\dp app.chunks` | app_rw=arwd, app_ro=r -- inherited automatically, zero explicit grant | OK | "ALTER DEFAULT PRIVILEGES applies automatically to every new table -- least-privilege isn't a one-time grant, it's a standing policy." |

### Architecture Note
Anthropic's API has no embeddings endpoint; this lab's vectors are synthetic (random) precisely to demonstrate index/ops behavior without needing a real embedding provider. A production build needs a separate embedding provider (Voyage AI, Azure OpenAI, or self-hosted).

## Phase 4 — App and pipeline layer: Vercel + Next.js
| # | Step | Command (short) | Evidence | Result | Key Takeaway |
|---|------|-----------------|----------|--------|--------------|
| 4.1 | Scaffold app | `create-next-app`; `npm i pg`; heredoc route.ts | web/ created, route reads app.chunks as app_ro | OK | n/a |
| 4.2 | Local run | `npm run dev` (background) + curl | {"now":"...","chunks":"20000"} -- works locally because MYIP is firewalled in | OK | n/a |
| 4.3 | Vercel deploy + prod test | `vercel link`; `vercel env add DATABASE_URL production`; `vercel deploy --prod` | Deploy succeeded -> https://ciplat-web.vercel.app; prod curl -> {"error":"timeout expired"} HTTP 500, 8.7s | OK | "Vercel functions have no stable egress IP, so a public Postgres with an IP allow-list is not a production posture. The health endpoint times out in 8.7s against the exact same database that answers instantly from my Mac." |
| 4.4 | Temp open + auto-revert proof | firewall-rule create 0.0.0.0-255.255.255.255 -> curl works -> explicit delete -> curl fails | Full round trip: FAIL(500) -> temp-open -> {"now":...,"chunks":"20000"} HTTP 200 -> revert confirmed -> FAIL(500) again | OK | "I isolated the cause definitively: opening the firewall to any IP made the identical endpoint succeed instantly, and reverting made it fail again -- this is the firewall, not the code or credentials." |
| 4.5 | Staging env scoping | `git checkout -b staging`; `vercel env add DATABASE_URL preview staging` | FAILED: "Project does not have a connected Git repository" | FAILED | "Environment variables are scoped per Vercel environment and per branch, but that scoping depends on the project being connected to a Git provider. A CLI-only deployment flow doesn't get real separation until that connection exists." |
| 4.6 | PgBouncer availability | `parameter show --name pgbouncer.enabled` | ERROR: "Server parameter 'pgbouncer.enabled' isn't supported in server 'pg-ciplat-dev-0a99'" | OK | "Built-in PgBouncer is not available on the Burstable tier -- confirmed directly against the server -- so pooling for serverless connections is either General Purpose tier in production or an external pooler." |

## Phase 5 — Staging + production, as code
| # | Step | Command (short) | Evidence | Result | Key Takeaway |
|---|------|-----------------|----------|--------|--------------|
| 5.1 | Terraform: remove risky dev module | Removed `module "pg_dev"` | main.tf rewritten, `terraform validate` clean | OK | "Dev was intentionally hand-built to have something to critique; the IaC module only ever targets stg/prod, and the config makes that boundary explicit rather than assumed." |
| 5.2 | envs/stg.tfvars + envs/prod.tfvars | tfvars files written | Both files written | OK | "The diff between stg.tfvars and prod.tfvars IS the environment policy -- reviewable in a PR, not tribal knowledge." |
| 5.3 | tf plan -> apply, stg then prod | `terraform plan -var-file=envs/stg.tfvars -out=stg.plan`; apply; same for prod | stg: Plan applied, pg-ciplat-stg-0a99 Ready. prod: same shape, pg-ciplat-prod-0a99 Ready. | OK | "I never apply without a saved plan in hand -- plan and apply are separate, reviewable steps, same as the dev-vs-prod diff itself." |
| 5.4 | Roles applied per environment | Same idempotent `sql/roles.sql` run against stg and prod | Both exit 0, identical output shape | OK | "The same role-provisioning script runs unchanged across every environment; only the credentials differ, and those come from a per-environment Vault path." |
| 5.4b | Cross-environment isolation | Connected to PROD using DEV's app_rw password; then PROD's own password | FIRST: password authentication failed (dev credential rejected). CONTROL: SUCCESS with prod's own credential | OK | "This isn't a design claim -- I tested it: a credential that works in dev is refused by production outright. Isolation is enforced by Postgres itself." |
| 5.5 | Versioned migration | Copied roles SQL into `sql/migrations/0001_init.sql`; fixed `/api/health` | File created; route.ts updated | OK | "Schema changes are a versioned, ordered file applied per environment -- not a table that happens to exist wherever someone last ran a manual command." |
| 5.6 | Promotion demo | Repointed Vercel's production `DATABASE_URL` from dev's app_ro to prod's app_ro | Deploy succeeded. Test: SAME failure as Phase 4 -- {"error":"timeout expired"}, HTTP 500. | OK | "Promoting the app to point at the real production database did not fix connectivity, because the underlying problem is structural: every environment has the same public-IP-allowlist model. This proves the fix has to be architectural: Vercel cannot join the VNet, so it is static egress IPs (Secure Compute), an API layer inside the VNet over Private Link, or moving the app into Azure -- see Phase 6.4." |
## Phase 6 — Pre-submission review (three-hat audit: Vercel, Azure Postgres, SOC 2)
| # | Step | Command (short) | Evidence | Result | Key Takeaway |
|---|------|-----------------|----------|--------|--------------|
| 6.1 | Claim-vs-code audit | Read response doc against `sql/roles.sql`, `envs/*.tfvars`, log | Response claimed `REVOKE ALL ON SCHEMA PUBLIC FROM PUBLIC`; script only revoked on DATABASE. Response said "~90 minutes" while README said "longer than 90 minutes". Response said "connection refused" while log 5.6 says `timeout expired`. | FIXED | "Every falsifiable sentence in a write-up must trace to a file or a log line; the review found three that did not." |
| 6.2 | Apply the missing REVOKE, all 3 envs | `REVOKE ALL ON SCHEMA public FROM PUBLIC` via psql as pgadmin from Vault; `has_schema_privilege('public','public',...)` before/after | dev/stg/prod identical: before `CREATE=false` (already removed by the PG15+ default), after `CREATE=false, USAGE=false`; `app_rw` USAGE on schema `app` still `true` | OK | "PG15+ already strips CREATE on public from PUBLIC; the REVOKE closes USAGE too, so no role touches public at all. Verified rather than assumed, and now the script matches the sentence." |
| 6.3 | SQL sources updated | `sed` on `sql/roles.sql` and `sql/migrations/0001_init.sql` | Line 11 in both: `REVOKE ALL ON SCHEMA public FROM PUBLIC;` | OK | n/a |
| 6.4 | Vercel networking correction | Reviewed Phase 5.6 takeaway against Vercel platform capabilities | Vercel functions cannot attach to an Azure VNet or consume a Private Endpoint; "VNet integration / Private Link" applied to Vercel was wrong. Response rewritten with the three real options (Secure Compute static egress IPs; API layer in the VNet over Private Link; move the app into Azure). Private Link remains correct for self-hosted n8n. | FIXED | "The finding (public allow-list is the #1 blocker) stood; the proposed fix did not. Name the option set the platform actually supports." |
| 6.5 | SOC 2 gaps added to the response | Doc edit | Added: pgaudit + log destination/retention in Q1; TLS (`require_secure_transport`); Vercel *Sensitive* env vars; CI-only prod applies as the change-management control in Q2; LLM data path (data classes, ZDR/no-training terms, prompt/response logging with correlation IDs) in Q3; explicit assumptions block (n8n self-hosted, regulated data, no embeddings, small team). Reworded "35 days to align with SOC 2" -> Azure max, must match the written retention policy. | OK | "SOC 2 does not prescribe numbers; it asks whether your numbers match your written policy and whether you can show evidence." |
| 6.6 | Honesty items surfaced in the doc | Doc edit | Time spent restated truthfully; rollback not live-tested and n8n not run moved into "given more time"; prod.tfvars lab-safe-vs-real values explained in the response, not only in the file | OK | n/a |
| 6.7 | README notes | `awk` block replacement | Two notes to a named contact replaced by one neutral note to the team: acknowledges the time-box, explains the build gave measured numbers, offers to adapt scope. | OK | n/a |

### Technical Notes
- `has_schema_privilege('public', 'public', 'CREATE')` is the cheap check for whether PUBLIC can still create in the default schema; PG15+ servers return `false` out of the box, PG14 and earlier return `true`.
- Side observation, not changed: dev is PG17, stg/prod are PG16 (`az postgres flexible-server list`). Same drift class as Phase 5.5 — the hand-built environment differs from the coded ones. Worth pinning `version` in the module.
