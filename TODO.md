# data-pipeline-infra — TODO

Task list only. Strategy, phase goals, the hardening brief and the decision log:
[`DEVELOPMENT.md`](DEVELOPMENT.md). Architecture: [`DESIGN.md`](DESIGN.md).

**v1 = Phases 0–6** (live). Next: **Hardening** and the open Phase 7 wiring, then
Phase 8 (per-unit cadence).

Legend: `[ ]` todo · `[~]` in progress · `[x]` done.

---

## Phase 0 — Repo & tooling

- [x] Choose IaC tool — Terraform 1.9.5, pinned via `.terraform-version` + `required_version`
- [x] GCS bucket for remote Terraform state (manual bootstrap, versioned)
- [x] Layout: `modules/{worker-job,pipeline,observability}` library; consumer roots live in consumer repos; `examples/minimal` as the CI fixture
- [x] `terraform fmt -check -recursive` + `terraform validate` in CI against `examples/minimal` (no backend, no creds)
- [x] Env strategy: single `dev` project for now, per-project later
- [ ] CI `plan` / `apply` gating — needs Workload Identity Federation credentials (deferred)

## Phase 1 — Container image

- [x] `Dockerfile` for the worker (uv, named build-context for the SDK, `--platform linux/amd64`) — lives in the consumer repo
- [x] **Artifact Registry** Docker repo, created by the `pipeline` module
- [x] Build + push by git SHA via `build.sh` — resolves the digest and pins it into the consumer's tfvars
- [ ] CI image build/push automation (deferred — `build.sh` covers it today)

## Phase 2 — Storage

- [x] **GCS raw bucket** (`<prefix>-<project>-raw`) with a lifecycle TTL (default 30 days) and uniform bucket-level access
- [x] **GCS curated bucket** — object versioning on, no TTL
- [x] Auto-inject `${env_prefix}_RAW_BUCKET_URL` + `DESTINATION__FILESYSTEM__BUCKET_URL` + `${env_prefix}_LOG_FORMAT` from the module-owned buckets
- [ ] (Optional, defer until the `latest` role ships) **Memorystore Redis** for hot state + cross-run breaker persistence

## Phase 3 — Secrets & IAM

- [x] Per-consumer **service accounts**: worker (runtime) + scheduler (invoker)
- [x] **Secret Manager** support — per-job `secret_env` (name → secret id + version), grants deduped across jobs
- [x] Secret grants ordered **before** the jobs (`depends_on`) — Cloud Run checks secret access at job create/update time
- [x] Per-job `secret_env` **in production use** — winamax fetches through a residential proxy whose URL comes from Secret Manager
- [x] No secret values in the repo, tfvars or TF state — secret *ids* only

## Phase 4 — Cloud Run Job (v1)

- [x] `modules/worker-job` — one Cloud Run Job + optional cron + invoker IAM (the primitive)
- [x] `modules/pipeline` — batteries-included stack: APIs, storage, registry, identities, IAM, N jobs (the common entrypoint)
- [x] **Four ingest Jobs live**, one per bookmaker (betclic, winamax, unibet, pmu), driven off `catalog_urls` in the consumer root
- [x] Manual run confirmed — full harvest landed in the raw bucket

## Phase 5 — Fixed cadence (v1)

- [x] **Cloud Scheduler** hourly cron → Run Jobs Admin API `jobs:run` (OAuth, not OIDC)
- [x] `scheduler_region` knob — europe-west9 (Paris) is not a Scheduler location, so triggers live in europe-west1 and still call jobs in var.region
- [x] Interval as a per-consumer variable (`ingest_schedule` / `transform_schedule`)
- [x] Per-job retry policy (`max_retries`) and execution timeout (`timeout_seconds`)
- [x] `schedulers_paused = false` on the consumer root — **triggers live**

## Phase 6 — Transform & latest roles

- [~] **transform** Job instantiated (`PMA_ROLE=transform`, raw → curated) — trigger **paused**, never run end to end (user decision: raw-only for now)
- [ ] Confirm **idempotent replay** — re-running transform over the same raw upserts with no duplicate rows (validates the Delta-merge contract)
- [ ] (Optional) **latest** Job (`PMA_ROLE=latest` → Redis), gated on the Phase 2 Redis item

## Phase 7 — Observability

### Native alerts — no metrics pipeline

- [x] `modules/observability` — Cloud Monitoring alert policies over the native `run.googleapis.com/job/completed_execution_count{result}`, scoped to `${name_prefix}-*`
- [x] **Job-failure** alert (`result="failed" > 0`, grouped by job name)
- [x] **Freshness / silent-stall** alert (absence of `result="succeeded"`, default 2h window)
- [x] Optional email notification channel (empty address = channel-less policies)
- [x] **Wired into the consumer root** — `proba-markets-analysis/infra/dev` calls `module "observability"`; applied 2026-08-27 (2 policies + 1 email channel live in `proba-market-analysis`)

### Prometheus tier — Grafana Cloud via OTLP

- [x] **SDK OTLP push** (`data-pipeline-core` `obs/otlp_push.py`) — worker writes its final series to the OTLP gateway at exit, no PushGateway
- [x] **`pipeline` module wires it** — `metrics_otlp_url` / `_username` / `_token_secret` inject `${env_prefix}_METRICS_OTLP_*` and grant the worker SA `secretAccessor` on the token
- [x] Grafana Cloud stack created; `metrics:write` access-policy token in Secret Manager (`grafana-otlp-token`); the three vars set on the consumer root
- [x] Metrics **confirmed live** in Grafana Cloud (`worker_up`, `worker_runs_total{status}`, `records_written_total`, `bytes_written_total`)
- [ ] `ingestion_lag_seconds` freshness + **circuit-breaker** + **proxy-ratio** alerts — candidate home: Grafana-managed alerts beside the dashboard

### Technical dashboard

- [x] `dashboards/technical.json` — 7 panels over the frozen SDK series (workers executed, errors, error ratio, runs/errors per source, records, bytes)
- [x] Datasource as a **template variable** so the JSON imports against any Prometheus backend
- [x] Counter panels use `sum_over_time()` — push-once counters are sparse and reset per run, so `increase()`/`rate()` render empty
- [x] **Imported in Grafana** against the Grafana Cloud datasource, reading real series
- [ ] (Deferred) total **GCS bucket footprint** panel — a bucket property, not a per-run metric; needs a size probe (scheduled job → gauge)

## Hardening — review 2026-08-27

Rationale for each item in [`DEVELOPMENT.md`](DEVELOPMENT.md) "Hardening goals".

- [x] **H1** — `terraform test` suite with provider mocks (`command = plan`, no creds), wired into CI. 11 runs: no-schedule ⇒ no scheduler/invoker; two jobs sharing a secret ⇒ one IAM member; `injected_env` carries `${env_prefix}_RAW_BUCKET_URL`; OTLP off ⇒ no env and no token grant, on ⇒ both; the three half-configured OTLP states rejected at plan time. Lives **per module** (`modules/*/tests/`), not against `examples/minimal` as first scoped — assertions can only reach the root module of the configuration under test, and from the fixture everything worth asserting is inside `module.pipeline`. Needed one new output, `pipeline.injected_env`, for the same reason. Each assertion was mutation-checked (break the guard ⇒ the run fails)
- [x] **H2** — raw-bucket grant narrowed from `objectAdmin` to `objectCreator` + `objectViewer`; curated keeps `objectAdmin` for dlt's Delta merge. Safe because the SDK's landing sink names every object `{timestamp}-{uuid}.jsonl` and so never replaces one, and the transform role only globs + reads — the contract needs no delete on raw. The lifecycle TTL is unaffected (GCS enforces it, not the SA). Covered by `tests/bucket_grants.tftest.hcl` (3 runs, mutation-checked); the identity run uses `command = apply` against the mock because the SA email is unknown at plan time and `override_during` doesn't exist in the pinned 1.9.5
- [x] **H3** — add a `watched_jobs` input to `observability` and `group_by_fields = ["resource.label.job_name"]` on the freshness alert, so one healthy job stops masking three dead ones (fleet-wide reduce exists only to keep the paused transform quiet)
- [ ] **H4** — `validation` blocks: `name_prefix` ≤ 20 chars (SA `account_id` limit is 30 and `-scheduler` costs 10), `image` matches `@sha256:`, `scheduler_service_account_email` required when `schedule != null`
- [ ] **H5** — a `labels` input merged onto jobs, buckets and the registry, so the billing export is sliceable per consumer and per job (cost is DESIGN §5's central argument)
- [ ] **H6** — cut **`v0.1.0`** (annotated tag) and document in the README that a local-path `source` is co-dev only; consumers pin `?ref=`
- [ ] **H7** — add `depends_on = [google_project_service.apis]` to the two `google_service_account` resources, matching the buckets and the registry (first-apply race on a fresh project)
- [ ] **H8** — drop the stale "greenfield, nothing is deployed yet" status block from `DESIGN.md`; status lives in `DEVELOPMENT.md`

## Phase 8 — Per-unit volatility cadence (v2)

Prereqs in `data-pipeline-core` (build these first): a **single-work-unit run**
(config-selected unit instead of the whole-source loop) and the **scheduling hint**
(`next_run_seconds`).

- [ ] **Cloud Tasks** queue; tasks trigger a Job execution **per work unit** via the Run Jobs API with a runtime override carrying the unit id
- [ ] Worker computes its next delay (consumer logic) → the SDK hook enqueues the next task with `schedule_time = now + clamp(delay)` — one self-paced chain per unit
- [ ] **Clamp** `[min, max]` enforced infra-side (tied to the IP-guard / budget floor)
- [ ] Keep a slow **floor / catalog-refresh** run that re-seeds a dead chain and seeds chains for newly-appeared units
- [ ] Grant the worker SA `cloudtasks.enqueuer` + `run.jobs run` for self-enqueue
- [ ] Retire (or down-rate) the Phase 5 whole-source cron once per-unit chains cover all units
