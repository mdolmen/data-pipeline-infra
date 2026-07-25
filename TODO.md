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

## Status (2026-06-24) — v1 LIVE

`proba-markets-analysis` is deployed and **hoarding raw hourly** from Cloud Run.
First production run landed 174 clean 1X2 records across 26 competitions.

- **Done:** Phases 0–5 (Terraform module library, GCS raw+curated, registry,
  SA/IAM, ingest Job, hourly cron — `pma-ingest-trigger` live in `europe-west1`).
- **Deployed but paused:** transform Job (`pma-transform-trigger` paused — raw-only
  for now; not yet run end-to-end). Phase 6 partial.
- **Known gap (do soon):** no failure/freshness **alert** (Phase 7). A silent
  collection stall is the one thing that can't be backfilled — the highest-value
  next infra item.
- **Open watch item:** ingest **egress block rate** — Cloud Run IPs intermittently
  get DataDome/geo-blocked; the worker logs it (`catalog has no sport menu …`)
  and exits cleanly. If frequent → residential FR proxy (`ProxyRouter`).
- **Deferred:** Phase 7 (full observability), Phase 8 (v2 per-competition cadence),
  CI image build/push (today via `build.sh`), `latest` role + Redis.

---

## Phase 0 — Repo & tooling

- [x] Choose IaC tool (**Terraform** 1.9.5, pinned).
- [x] GCS bucket for **remote Terraform state** (manual bootstrap).
- [x] Project layout: `modules/{worker-job,pipeline}` library; consumer root lives
      in the consumer repo (`proba-markets-analysis/infra/dev`); `examples/minimal`.
- [x] Providers + backend + `terraform fmt`/`validate` in CI.
- [x] Env strategy: single project for now (`dev`), per-project later.
- [~] CI: `fmt` + `validate` wired; `plan`/`apply` gating needs WIF creds (deferred).

## Phase 1 — Container image

- [x] `Dockerfile` for the worker (uv, named build-context for the SDK,
      `--platform linux/amd64`).
- [x] **Artifact Registry** repo (Docker).
- [~] Build + push by git SHA via `build.sh` (resolves digest, pins tfvars). CI
      automation deferred.

## Phase 2 — Storage

- [x] **GCS raw bucket** (`pma-…-raw`) with 30-day retention lifecycle.
- [x] **GCS curated bucket** (`pma-…-curated`) — versioning on, no TTL.
- [x] Wire `DESTINATION__FILESYSTEM__BUCKET_URL` + raw bucket URL (auto-injected by
      the `pipeline` module from `env_prefix`).
- [ ] (Optional, defer until `latest` role ships) **Memorystore Redis** for hot
      state + cross-run breaker persistence.

## Phase 3 — Secrets & IAM

- [x] Per-service **service accounts** (worker + scheduler), least privilege:
      `objectAdmin` on the buckets, `run.invoker` for the scheduler.
- [x] **Secret Manager** support in the module (`secret_env`); v1 needs no secrets
      (Betclic is anonymous, GCS auth via the worker SA).
- [x] No secrets in TF state / repo.

## Phase 4 — Cloud Run Job (ingest, whole-source loop) — v1

- [x] `modules/worker-job` + `modules/pipeline` (batteries-included stack).
- [x] Instantiate the **ingest** job (`PMA_ROLE=ingest`, raw, firefox, all comps).
- [x] Manual run confirmed: 174 records / 26 competitions landed in the raw bucket.

## Phase 5 — Fixed cadence (v1)

- [x] **Cloud Scheduler** hourly cron (in `europe-west1` — Paris has no Scheduler;
      `scheduler_region` knob) → invokes the ingest Run Job. **Live.**
- [x] Interval as a per-service TF variable (`ingest_schedule`).
- [~] Job retry policy set (`max_retries`); failure **alert** still TODO → Phase 7.

## Phase 6 — Transform & latest roles

- [~] **transform** job instantiated (`PMA_ROLE=transform`, raw → curated) — but its
      trigger is **paused** (raw-only for now, user decision). Not yet run.
- [ ] (Optional) **latest** job (`PMA_ROLE=latest` → Redis), gated on Phase 2 Redis.
- [ ] Confirm idempotent replay: re-running transform over the same raw upserts
      (no dup rows) — validates the Delta-merge contract end-to-end. **Pending the
      first transform run.**

> **v1 deployed.** Raw is hoarding hourly; transform is built but parked. Next:
> a freshness/failure alert (Phase 7 slice), then per-competition cadence (Phase 8).

## Phase 7 — Observability & alerting

Split into two tiers by dependency (`modules/observability`): **native alerts**
(Cloud Monitoring, no metrics pipeline) ship now and close the un-backfillable
gap; the **Prometheus tier** (live dashboard + breaker/proxy alerts) waits on the
metrics-backend decision.

### Native alerts — no metrics pipeline (done)

- [x] `modules/observability` — Cloud Monitoring alert policies over the native
      `run.googleapis.com/job/completed_execution_count{result}` metric + an email
      notification channel. Scoped to `${name_prefix}-*` jobs.
- [x] **Job-failure** alert (`result="failed" > 0`) — closes the known gap.
- [x] **Freshness / silent-stall** alert (absence of `result="succeeded"` for a
      window, default 2h) — guards the gap that can't be backfilled, without needing
      `ingestion_lag_seconds`.
- [ ] **Wire it into the consumer root** (`proba-markets-analysis/infra/dev`):
      `module "observability"` with `name_prefix = "pma"` + a notify email; apply.

### Prometheus tier — needs the metrics backend (DESIGN §8, open)

- [ ] **Decide + provision the metrics backend** and wire `metrics_push_gateway`.
      The SDK pushes via the **PushGateway protocol** today (remote-write deferred),
      so the realistic options are: (a) run a **Pushgateway** (Cloud Run service) +
      a scrape→Grafana Cloud/GMP, or (b) add **remote-write to the SDK** and target
      Managed Prometheus. This gates the two items below.
- [ ] `ingestion_lag_seconds` **freshness** and **circuit-breaker** /
      **proxy-ratio** alerts (these read the SDK custom series, so they need the
      backend above).
- [ ] Deploy `dashboards/technical.json` live (point the datasource var at the
      provisioned Prometheus; optionally via the Grafana TF provider).

### Technical dashboard (Grafana dashboard-as-JSON) — the "obs #1" deliverable (done)

- [x] `modules/observability/dashboards/technical.json` — a small panel set over
      the frozen series (runs, in-flight best-effort, errors, error-ratio, records &
      bytes written), datasource as a **template variable** so it imports against any
      Prometheus backend. Per day/week/month via the range picker.
- [x] In-flight caveat noted on the panel (push-at-exit jobs → last-push count, not
      a true live gauge).
- [ ] **Deferred follow-up:** total **GCS bucket footprint** (GB in raw/curated) is
      a property of the bucket, not a per-run metric — add a size probe/exporter
      (scheduled job → gauge) if a true footprint panel is wanted later.

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
| Alerts before a metrics pipeline | Native Cloud Monitoring (failure + freshness) ships first, no Prometheus | Cloud Run Jobs emit `completed_execution_count{result}` for free; the un-backfillable gap is closable today, before the metrics-backend decision. |
| Technical dashboard datasource | Template variable, not a hard-pinned source | Backend is undecided (DESIGN §8); a datasource var keeps the JSON importable against Grafana Cloud / GMP / self-hosted alike. |
| Metrics backend | Still open — gates only the Prometheus tier | SDK pushes via PushGateway protocol today; remote-write is deferred SDK work. Pick Pushgateway-shim vs GMP+remote-write when breaker/proxy alerting or a live dashboard is actually needed. |
