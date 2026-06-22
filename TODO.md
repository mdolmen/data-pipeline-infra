# data-pipeline-infra — Build Plan

Phased, tracer-bullet order. **v1 = Phases 0–6**: one Cloud Run Job that loops all
competitions on a fixed hourly cron, landing raw — launch this and start hoarding
data. Then **Phase 7 (observability)**, then **Phase 8 (v2, per-competition
volatility cadence)** last. See `DESIGN.md` for the architecture and the
service→infra contract.

Substrate is **Cloud Run Jobs** throughout (scale-to-zero, no warm Service, no
HTTP serve layer) — the load is ~30 competitions × ~1 req/hour (volatility-
adjusted), i.e. a few requests per *minute* at peak. See DESIGN §5.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done.

---

## Phase 0 — Repo & tooling

- [ ] Choose IaC tool (default: **Terraform**) and pin version (`.terraform-version`).
- [ ] GCS bucket for **remote Terraform state** (versioned + locking).
- [ ] Project layout: `modules/` (reusable), `envs/dev`, `envs/prod` (or workspaces).
- [ ] Bootstrap providers (`google`, `google-beta`), backend config, `terraform fmt`/`validate` in CI.
- [ ] Decide env strategy: separate GCP projects per env (recommended) vs workspaces.
- [ ] CI: `fmt` → `validate` → `plan` on PR; `apply` gated on merge.

## Phase 1 — Container image

- [ ] `Dockerfile` for the worker (uv-based, runs `python -m workers.main`). Pin the
      base image; `curl_cffi` carries a native lib, so prefer an explicit Dockerfile
      over buildpacks for reproducibility. (Not strictly mandatory, but recommended.)
- [ ] **Artifact Registry** repo (Docker).
- [ ] CI: build + push image, tag by git SHA; expose the digest as a TF input.

## Phase 2 — Storage

- [ ] **GCS raw bucket** (bronze JSONL landing) — lifecycle rule for raw
      retention (the "raw retention = infra" decision; set the N-day TTL here).
- [ ] **GCS curated bucket** (Delta/Parquet) — no TTL; versioning on.
- [ ] Wire `DESTINATION__FILESYSTEM__BUCKET_URL` and the raw bucket URL into the job env.
- [ ] (Optional, defer until `latest` role ships) **Memorystore Redis** for hot
      state + cross-run breaker persistence.

## Phase 3 — Secrets & IAM

- [ ] Per-service **service account**, least privilege:
      `roles/storage.objectAdmin` scoped to its buckets, `secretmanager.secretAccessor`
      on its secrets, `run.invoker` (for the scheduler to trigger the Job).
- [ ] **Secret Manager** secrets for `PMA_*` sensitive config; map → Run Job env.
- [ ] No secrets in TF state / repo; reference by resource.

## Phase 4 — Cloud Run Job (ingest, whole-source loop) — v1

- [ ] `modules/worker-job`: reusable Cloud Run **Job** (image digest, env, secrets,
      SA, timeout, max-retries, resources), parameterized per role/service.
- [ ] Instantiate the **ingest** job for `proba-markets-analysis`: `PMA_ROLE=ingest`,
      `PMA_INGEST_OUTPUT=raw`, `PMA_CATALOG_URL=…`, `impersonate=firefox`, **no**
      `PMA_MAX_COMPETITIONS` (loop all ~30 competitions in one run, ~seconds).
- [ ] Manual `gcloud run jobs execute` → confirm raw JSONL for all competitions
      lands in the raw bucket.

## Phase 5 — Fixed cadence (v1)

- [ ] **Cloud Scheduler** hourly cron → invoke the ingest Run Job (OIDC invoker SA).
      This is the base 1 req/hour/competition rate (all units, one schedule).
- [ ] Interval as a per-service TF variable. Do **not** treat the cron as the
      eternal source of truth for cadence — it's the degenerate "constant delay,
      all units" case of the v2 mechanism (DESIGN §4/§6).
- [ ] Job retry policy + alert on repeated failure.

## Phase 6 — Transform & latest roles

- [ ] Instantiate **transform** job (`PMA_ROLE=transform`, raw → curated) on its own
      schedule (the "transform frequency = infra" decision). Batch replay of raw —
      a Job is the right tool here.
- [ ] (Optional) **latest** job (`PMA_ROLE=latest` → Redis), gated on Phase 2 Redis.
- [ ] Confirm idempotent replay: re-running transform over the same raw upserts
      (no dup rows) — validates the Delta-merge contract end-to-end.

> **v1 complete.** Raw is hoarding hourly; transform turns it into curated. The
> next two phases harden (observability) then evolve (per-competition cadence).

## Phase 7 — Observability & alerting

- [ ] Provision the metrics target (**Managed Prometheus** remote-write or a
      Pushgateway shim) and wire `metrics_push_gateway`.
- [ ] Alerts: job failure, **freshness** (`ingestion_lag_seconds` over threshold —
      a gap in the hoard is the one thing you can't backfill), circuit-breaker open
      (`circuit_breaker_state`), proxy ratio.
- [ ] Dashboards reference the SDK's frozen metric series (names/labels are stable).

## Phase 8 — Per-competition volatility cadence (v2)

> Prereqs (do first): (a) the **consumer/SDK** can target a **single competition**
> per run (granularity change — the v1 loop becomes per-unit), and (b) the SDK
> emits the **scheduling hint** (`next_run_seconds`). Build the SDK seam before the
> infra below.
- [ ] **Cloud Tasks** queue; tasks trigger a Job execution **per competition** via
      the Run Jobs API with a **runtime override** carrying the competition id.
- [ ] Worker computes the distance/volatility (consumer logic) → next delay; the
      SDK hook enqueues the next task for that competition with
      `schedule_time = now + clamp(delay)` — one self-paced chain per competition.
- [ ] **Clamp** `[min, max]` enforced infra-side (tie to IP-guard / budget floor).
- [ ] Keep a **slow "floor" / catalog-refresh** run that re-seeds a dead chain and
      seeds chains for newly-appeared competitions.
- [ ] Grant the worker SA `cloudtasks.enqueuer` + `run.jobs run` for self-enqueue.
- [ ] Retire (or down-rate) the Phase 5 whole-source cron once per-competition
      chains cover all units.

---

## Decision log

What's **GCP-managed**, what's **declared here**, what's **deferred**.

| Item | Decision | Rationale |
|---|---|---|
| Substrate | **Cloud Run Jobs** (scale-to-zero), not a warm Service | Low-volume sporadic sub-second tasks; no idle cost, no serve layer, cold start irrelevant at minute/hour cadences. Tripwire: sub-second/real-time → warm Service (DESIGN §5). |
| Run cadence | Infra (one-shot + external scheduler) | Worker is stateless one-shot; scheduling is ops, not library/business. |
| v1 granularity | One Job loops **all** competitions on one cron | Simplest launch; uses the existing whole-source run. Start hoarding raw immediately. |
| v2 granularity | One self-paced chain **per competition** via Cloud Tasks | Per-competition volatility needs independent cadences; a single loop can't vary per unit. |
| Fixed cadence transport | Cloud Scheduler → Run Job | Simplest correct v1; cron is for fixed intervals. |
| Dynamic cadence transport | Cloud Tasks (`schedule_time`) → Run Jobs API + floor run | Scheduler can't self-pace; Tasks does one-off future runs. Floor re-seeds a broken chain. |
| Service → infra config | Single clamped scalar/enum (`next_run_seconds`) | Narrow waist; service requests, infra enforces `[min,max]`. No ops knobs cross the line. |
| Scheduling-hint interface | SDK (deferred), like Pub/Sub | Shared shape both consumer (emits) and infra (consumes) depend on. |
| Raw retention | Infra (GCS lifecycle TTL) | Bucket-level policy, not app logic. |
| Transform frequency | Infra (own schedule) | Same category as ingest cadence. |
| Secrets | Secret Manager → env | Never in repo/state. |
| Reusability | `modules/worker-job`, per-service instances | Generic + first consumer (proba-markets-analysis), mirrors the SDK model. |
| IaC tool | Terraform (assumed; confirm Phase 0) | Mainstream GCP IaC; revisit if a reason appears. |
| Build order | v1: Phases 0–6 → Phase 7 (obs) → Phase 8 (v2) | Launch + hoard first; harden; then per-competition volatility. |
