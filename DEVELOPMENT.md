# DEVELOPMENT.md — how this build is run

Companion to [`TODO.md`](TODO.md), which holds the checkbox task list only. This
file holds the *why*: strategy, phase goals, per-phase rationale, the hardening
brief, and the decision log. **Task status lives in `TODO.md`** — this file is
reference, not a checklist.

Architecture and the target design: [`DESIGN.md`](DESIGN.md). Module usage:
[`README.md`](README.md) and [`modules/observability/README.md`](modules/observability/README.md).

---

## Context & strategy

- **This repo is a module library, not an environment.** It owns the *generic*
  substrate (Cloud Run Jobs, storage, registry, identities, scheduling, alerts);
  each consumer keeps its own thin Terraform root **in its own repo** and imports
  these modules. That mirrors how each consumer imports the `data-pipeline-core`
  SDK. `envs/` was deliberately removed once the first consumer had a root.
- **Tracer-bullet, launch-first order.** v1 = Phases 0–6: one Cloud Run Job on a
  fixed hourly cron landing raw. Ship that and start hoarding, *then* harden
  (Phase 7 observability), *then* build per-unit cadence (Phase 8). A gap in the
  raw hoard cannot be backfilled; a missing dashboard can.
- **Co-dev with the first consumer.** `proba-markets-analysis` drives the module
  API. During co-dev the consumer's `source` points at a local sibling path
  (`../../../data-pipeline-infra/modules/pipeline`) — the same editable trick as
  the SDK. Swap to a pinned `?ref=vX.Y.Z` once the API stabilises.
- **Single consumer = overfitting risk.** For every input, sanity-check: would a
  second consumer (`airbnb-intel`, Polytricks) use it the same way? If not, it is
  consumer config, not module design. The module knows about "an image, a role, an
  env, a schedule" — never about the domain.

Substrate is **Cloud Run Jobs** throughout (scale-to-zero, no warm Service, no HTTP
serve layer) — the load is a few requests per *minute* at peak. See DESIGN §5 for
the tripwire that would justify a warm Service instead.

---

## Status (2026-08-27) — v1 live, 4 bookmakers, metrics + alerting on

`proba-markets-analysis` is deployed and hoarding raw hourly from Cloud Run, with
one ingest Job per bookmaker.

- **Live:** Phases 0–5. Four ingest Jobs (`pma-ingest-{betclic,winamax,unibet,pmu}`)
  on an hourly cron via `pma-*-trigger` in `europe-west1`; raw + curated buckets;
  Artifact Registry; worker + scheduler SAs. `schedulers_paused = false`.
- **Live:** OTLP metrics push to Grafana Cloud, wired by the `pipeline` module
  (`metrics_otlp_*` → `PMA_METRICS_OTLP_*` env + a Secret-Manager token). The
  technical dashboard is imported and reading real series.
- **In production use:** per-job `secret_env` — winamax fetches through a
  residential proxy whose URL comes from Secret Manager (`winamax-proxy-url`). The
  module dedupes the secret grants across jobs.
- **Live:** `modules/observability`, wired into the consumer root and applied
  2026-08-27 — the job-failure and freshness/stall policies now email a single
  address. Note the stall policy is still fleet-wide (**H3**): with four ingest
  Jobs, one healthy bookmaker suppresses it for the other three.
- **Deployed but paused:** the transform Job (`paused = true` — raw-only for now,
  user decision). Never run end-to-end; the idempotent-replay check is still open.
- **Deferred:** Phase 8 (v2 per-unit cadence), CI image build/push (today via
  `build.sh`), the `latest` role + Redis, `terraform plan` gating in CI (needs WIF).

---

## Phase goals

- **Phase 0 — Repo & tooling.** Pin the toolchain, get remote state, settle the
  layout (modules library here, consumer roots in consumer repos), and get `fmt` +
  `validate` running in CI against a fixture.
- **Phase 1 — Container image.** A worker image in Artifact Registry, pinned by
  digest. Terraform consumes a digest; it never builds.
- **Phase 2 — Storage.** Raw (bronze) JSONL bucket with a lifecycle TTL, curated
  (lakehouse) bucket with versioning. The module owns the buckets, so it can also
  inject their URLs as SDK-standard env — the consumer never repeats them.
- **Phase 3 — Secrets & IAM.** Per-consumer worker + scheduler service accounts,
  and Secret-Manager-backed env for anything that must not sit in plain env. No
  secret value ever enters tfvars or state — only secret *ids*.
- **Phase 4 — Cloud Run Job (v1).** The two-module split: `worker-job` is the
  primitive (one Job + optional cron + IAM), `pipeline` is the batteries-included
  composition (APIs + storage + registry + identities + IAM + N jobs). A consumer
  gets the whole stack from one module call.
- **Phase 5 — Fixed cadence (v1).** Cloud Scheduler → Run Jobs Admin API
  (`jobs:run`, OAuth not OIDC — it is a Google API). Deploy paused by default and
  flip to live deliberately; `scheduler_region` exists because europe-west9 is not
  a Scheduler location.
- **Phase 6 — Transform & latest roles.** Prove the second archetype: a transform
  Job on its own schedule, replaying raw into curated. The open question is
  idempotent replay, which validates the Delta-merge contract end to end.
- **Phase 7 — Observability.** Split by dependency, below.
- **Phase 8 — Per-unit volatility cadence (v2).** Cloud Tasks chains, one per work
  unit, self-paced by a clamped scalar from the worker. Blocked on two SDK seams
  (single-unit run, `next_run_seconds`); build those before any infra here.

---

## Observability — why the two-tier split

`modules/observability` is deliberately split by *what each piece depends on*.

- **Native tier (no metrics pipeline).** Cloud Run Jobs emit
  `run.googleapis.com/job/completed_execution_count{result}` to Cloud Monitoring
  for free. So **job-failure** (`result="failed" > 0`) and **freshness/stall**
  (`result="succeeded"` absent for a window) are plain alert policies that work the
  moment a job has run once. These are the two "can't-be-backfilled" alerts, so
  they ship first and wait on nothing.
- **Prometheus tier.** The technical dashboard and the breaker/proxy alerts read
  the SDK's custom series, so they need metrics actually flowing. Backend is
  Grafana Cloud via OTLP/HTTP push at exit — no always-on PushGateway + scraper for
  short-lived jobs. Grafana Cloud surfaces OTLP, not remote-write, for custom
  metrics.

**Dashboard counter panels use `sum_over_time()`, not `increase()`/`rate()`.**
Workers are short-lived and push **one sample per run**, each run's counter
starting at 0 — the series is sparse and non-monotonic across runs.
`increase()`/`rate()` need ≥2 samples per bucket and return *nothing* on push-once
data, which looks like an empty panel. Don't switch them back.

**Absence conditions need a prior sample.** The freshness alert fires when the
success series goes *absent*; a job that has never succeeded once has no series to
go absent, so it will not alert. Acceptable — the alert guards a running pipeline
going quiet, which is the actual failure mode.

---

## Hardening goals (review 2026-08-27)

Reviewed the library end to end. The design and the docs are sound; what is missing
is the guardrail layer — the repo has no way to catch a regression that
`terraform validate` does not see, and two stated properties are not actually
enforced by the code. Tasks are in `TODO.md` under "Hardening"; rationale here.

- **H1 — No tests beyond `validate`.** `terraform validate` catches type and syntax
  errors, not logic: nothing today would catch a `for_each` that silently drops a
  job, a secret grant that stops being deduped, or an injected env var losing its
  prefix. Terraform is pinned at 1.9.5, so the native test framework (1.6+) with
  provider mocks is available at zero infra cost — `terraform test` running
  `command = plan` against `examples/minimal`, no credentials, no cloud calls.
  Worth asserting: a job with `schedule = null` creates no scheduler and no invoker
  binding; two jobs referencing the same secret produce exactly one IAM member;
  `injected_env` carries `${env_prefix}_RAW_BUCKET_URL`; `metrics_otlp_url = ""`
  creates no token grant and no OTLP env. This is the single biggest gap.

  **Done.** 11 runs across `modules/pipeline/tests/` and
  `modules/worker-job/tests/`, wired into CI. Two things came out differently
  from the scoping above. The suite lives *per module* rather than against
  `examples/minimal`: test assertions can only reach resources in the root module
  of the configuration under test, and from the fixture every resource worth
  asserting is inside `module.pipeline`, reachable only through outputs — which
  is also why `pipeline` gained an `injected_env` output. And the OTLP assertion
  turned out to be checking a property the code did not have; fixing that first
  (the inputs are now validated as a set) is what the extra rejection runs pin.
  Every assertion was mutation-checked — break the guard, watch the run fail —
  because a test that has never failed proves nothing.
- **H2 — "Least privilege" is claimed but not delivered.** DESIGN §3 and Phase 3
  both say least privilege; the code grants `roles/storage.objectAdmin` on *both*
  buckets. The worker only ever writes to raw, yet the grant lets it delete the
  hoard — directly contradicting the threat model the freshness alert exists to
  defend, and the reason `force_destroy = false` is set. Split it:
  `objectCreator` + `objectViewer` on raw, keep `objectAdmin` on curated (dlt's
  Delta merge rewrites and deletes files there). Make it an input if a consumer
  ever needs a raw-mutating role.
- **H3 — The freshness alert cannot see a single dead job.** The stall policy
  reduces with `REDUCE_SUM` and **no `group_by_fields`**, so all watched jobs
  collapse into one series and any single success suppresses the alert for the
  whole fleet — while the failure policy immediately above it *does* group by
  `job_name`. With four ingest jobs live, three could die silently. Grouping
  naively would make the deliberately-paused transform Job alert forever, which is
  presumably why it is fleet-wide; the fix is therefore an explicit `watched_jobs`
  input (default: all `${name_prefix}-*`) plus `group_by_fields`, not just adding
  the grouping.
- **H4 — No `validation` blocks anywhere.** `name_prefix` over 20 characters
  silently blows the 30-char service-account `account_id` limit
  (`${name_prefix}-scheduler`) and surfaces as an opaque GCP API error on apply,
  after other resources have been created. `image` is documented as digest-pinned
  but nothing enforces `@sha256:`. `scheduler_service_account_email` is
  optional-but-required-when-`schedule`-is-set, enforced only by a comment. Four
  cheap blocks that move failures from apply-time to plan-time.

  Built with one guard beyond the brief: `name_prefix` is also checked for
  *shape*, not just length. Service account ids and bucket names are both
  lowercase-only, and the neighbouring `env_prefix` is upper-case by convention
  (`PMA`, `AIRBNB`) — so passing that value to `name_prefix` is an easy mistake
  that fails exactly like the length case, opaquely and mid-apply. The digest
  check lives on both `pipeline` and `worker-job`, since each is independently
  consumable and should guard its own inputs.
- **H5 — No resource labels.** DESIGN §5 makes cost the central argument for Jobs,
  then ships nothing to attribute cost. A `labels` input merged onto jobs, buckets
  and the registry makes the billing export sliceable per consumer and per job.
- **H6 — The versioning story is aspirational.** The README tells consumers to pin
  `?ref=v1.0.0`; there are no tags. The API has been stable across the last several
  commits and a real consumer is running on it — cut `v0.1.0` and note in the
  README that consumers stay on a local path only during active co-dev.
- **H7 — Inconsistent API-enablement ordering.** Buckets and the registry
  `depends_on` `google_project_service.apis`; the two service accounts do not.
  Harmless on a project where `iam.googleapis.com` is already on (as it is today),
  but it is a first-apply race on a genuinely fresh project and an inconsistency a
  reviewer will read as an oversight either way.
- **H8 — `DESIGN.md` opens with a stale status line.** It still says "greenfield,
  nothing is deployed yet" while v1 has been live for two months. DESIGN should
  carry no status at all — status belongs here.

---

## Backlog policy

Deferred items are tracked, not blocking. Promote one when a real consumer needs
it — generalize on the *second* real usage, not the first.

**Not infra — belongs to `data-pipeline-core`:** single-work-unit runs and the
`next_run_seconds` scheduling hint. Both are SDK seams and both are prerequisites
for Phase 8; no infra work here starts before they exist.

**Not infra — belongs to the consumer:** cadence *values*, business env, which
sources get proxy credentials, the catalog URLs. Infra enforces bounds; the service
requests.

---

## Decision log (keep updated — briefs the future Polytricks instance)

| Item | Decision | Rationale |
|---|---|---|
| Substrate | **Cloud Run Jobs** (scale-to-zero), not a warm Service | Low-volume sporadic sub-second tasks; no idle cost, no serve layer, cold start irrelevant at minute/hour cadences. Tripwire: sub-second/real-time → warm Service (DESIGN §5) |
| Repo shape | Modules library only; consumer roots live in consumer repos | Mirrors the SDK model; an `envs/` dir in a library couples it to one consumer |
| Run cadence | Infra (one-shot + external scheduler) | Worker is stateless one-shot; scheduling is ops, not library/business |
| v1 granularity | One Job loops **all** work units on one cron | Simplest launch; uses the existing whole-source run. Start hoarding raw immediately |
| v2 granularity | One self-paced chain **per unit** via Cloud Tasks | Per-unit volatility needs independent cadences; a single loop can't vary per unit |
| Fixed cadence transport | Cloud Scheduler → Run Jobs Admin API (OAuth) | Simplest correct v1; `jobs:run` is a Google API, so OAuth not OIDC |
| Dynamic cadence transport | Cloud Tasks (`schedule_time`) → Run Jobs API + floor run | Scheduler can't self-pace; Tasks does one-off future runs. Floor re-seeds a broken chain |
| Service → infra config | Single clamped scalar/enum (`next_run_seconds`) | Narrow waist; service requests, infra enforces `[min,max]`. No ops knobs cross the line |
| Scheduling-hint interface | SDK (deferred) | Shared shape both consumer (emits) and infra (consumes) depend on |
| Two-module split | `worker-job` primitive + `pipeline` composition | Granular hand-composition stays possible; the common case is one module call |
| Deploy state | `schedulers_paused = true` by default | Apply is separable from go-live; flipping to false is the deliberate launch step |
| Image | Digest-pinned, built out of band | Terraform consumes artifacts, it doesn't build them; a digest makes the job spec reproducible |
| Raw retention | Infra (GCS lifecycle TTL) | Bucket-level policy, not app logic |
| Secrets | Secret Manager → env, secret *ids* only in tfvars | Never in repo/state. Grants deduped across jobs, ordered before the jobs (Cloud Run checks secret access at create time) |
| CI validation | `fmt` + `validate` against `examples/minimal` | Modules can't be validated standalone; the fixture is non-deployable and needs no credentials |
| `plan`/`apply` in CI | Deferred | Needs Workload Identity Federation against a real project; `validate` covers the library's own regressions |
| Alerts before a metrics pipeline | Native Cloud Monitoring (failure + freshness) ships first | Cloud Run Jobs emit `completed_execution_count{result}` for free; the un-backfillable gap is closable without Prometheus |
| Technical dashboard datasource | Template variable, not a hard-pinned source | Keeps the JSON importable against Grafana Cloud / GMP / self-hosted alike |
| Dashboard deployment | Manual import, not the Grafana TF provider | One import against an external account; a provider + credentials is more machinery than the step is worth today |
| Metrics backend | **Grafana Cloud** via SDK **OTLP/HTTP push** | Short-lived jobs write at exit — no always-on PushGateway + scraper. Grafana Cloud surfaces OTLP (not remote-write) for custom metrics; OTLP-JSON is zero-dep in the SDK |
| Counter panels | `sum_over_time()`, not `increase()`/`rate()` | Push-once counters are sparse and reset per run; rate functions return nothing and the panel reads as empty |
| Build order | v1: Phases 0–6 → Phase 7 (obs) → Phase 8 (v2) | Launch + hoard first; harden; then per-unit volatility |
| OTLP inputs | url + username + token secret validated as **all-or-nothing** | One feature, three inputs. Each half-configured state failed quietly: a url without credentials pushes to an authenticated gateway and the SDK swallows the failure by design (a permanently empty dashboard on a worker reporting success); credentials without a url leave a `secretAccessor` grant on a switched-off feature. Gating alone fixes only the second, so the invalid states are rejected at plan time instead. Costs the unauthenticated-collector case — indistinguishable from a forgotten token, and no consumer needs it |
| Terraform floor | `>= 1.9` across all modules | Variable `validation` may reference *other* variables only from 1.9. Needed by the OTLP validation and by H4; raised before `v0.1.0` is tagged, so it is not a constraint change after consumers pin a ref |
| Module tests | Per module (`modules/*/tests/`), not against `examples/minimal` | `terraform test` assertions reach only the root module of the configuration under test; from the fixture every resource worth asserting sits inside `module.pipeline`. The fixture stays what it always was — a `validate` target |
