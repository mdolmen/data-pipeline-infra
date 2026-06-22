# data-pipeline-infra — Design

Infrastructure-as-code for deploying data-pipeline workers to GCP. This repo owns
**deployment, scheduling, storage provisioning, secrets, and IAM** — the
operational substrate for *any* worker built on the `data-pipeline-core` SDK. It
contains no ingestion logic (that's the SDK) and no business logic (that's the
consuming service). It is deliberately **consumer-agnostic**: a new SDK-based
service should be deployable by instantiating a module, with no changes to the
core design.

> Status: greenfield. Nothing is deployed yet. This document is the target
> architecture; `TODO.md` is the build order.

---

## 1. The three-layer split

| Layer | Owns | |
|---|---|---|
| `data-pipeline-core` (SDK) | In-process runtime: `WorkerApp`, Source/Sink/Transform, resilience, metrics, the **scheduling-hint interface** | mechanism |
| Consuming service(s) | Business logic: what to fetch, the canonical schema, **the cadence *value*** | policy |
| `data-pipeline-infra` (this repo) | Deployment + orchestration: how/when/where a worker runs, **cadence enforcement** | ops |

Rule of thumb: **mechanism = SDK, policy = the service, ops = infra.** A service
*requests*; infra *enforces bounds*. Infra knows about "a worker image, a role,
an env, a schedule" — never about the domain a given service operates in.

---

## 2. Execution model — one-shot Jobs

An SDK worker is a **stateless one-shot process**: its entry point does one
`fetch → (transform) → write` and exits with a code. There is no internal loop.
"Time between two runs" is therefore an **external scheduling** concern, owned
here. This keeps every run an independent, idempotent tick (curated writes are
keyed on a stable record id, merge-on-write to the lake, so re-runs never
duplicate), and lets the orchestrator provide retries, overlap policy, and
failure alerting for free.

The substrate is **Cloud Run Jobs**, not a long-lived Service:

- **Scale to zero.** A Job bills per-100ms only while running and costs nothing
  between executions — no idle instance to pay for.
- **Cold start is a non-issue** at these cadences (poll intervals measured in
  minutes/hours, not sub-second), so a few seconds of container/interpreter
  startup is irrelevant.
- **No HTTP serve layer.** The Job runs the SDK's one-shot CLI directly; there is
  no web framework, no request handler, nothing extra to build.

See §5 for when a warm Service would instead be warranted.

**Roles** (each deployable as its own Job + schedule):

- `ingest` — source → raw-landing (immutable JSONL on object storage).
- `transform` — raw-landing → transform → curated (lakehouse table).
- `latest` — raw-landing → hot store (optional key/value snapshot).
- `combined` — source → transform → curated in a single run (dev / low-volume).

**Work-unit granularity.** A source is made of independent **work units** (the
consumer defines the unit — e.g. a market, a competition, a region). A worker can
run for **all** of a source's units in one pass, or for a **single** unit. This is
the v1→v2 boundary (§4): v1 runs one Job over all units at a single cadence; v2
fans out to one self-paced invocation per unit.

---

## 3. GCP resource graph

GCP provides the managed *mechanisms*; this repo *declares and wires* them (IaC,
Terraform).

```
Artifact Registry (worker image)
        │
        ▼
Cloud Run Job ──reads──► Secret Manager (per-service secrets)
   │   │      ──writes─► Object storage (raw bucket: JSONL ; curated bucket: lakehouse)
   │   │      ──opt────► Memorystore Redis (hot state + cross-run breaker state)
   │   │      ──push───► Managed Prometheus / Pushgateway (metrics at exit)
   │   │
   │   └── execution triggered by:
   │         • Cloud Scheduler (fixed cron, whole-source loop)        [v1]
   │         • Cloud Tasks (per-unit, schedule_time, runtime override) [v2]
   │
   └── service account (least privilege: object admin on its buckets,
       secretAccessor on its secrets, run.invoker / run.jobs run, tasks enqueuer)
```

What's **managed by GCP** (free): container execution, retries/timeouts, cron
firing, task scheduling, secret storage. What's **ours to write**: the resource
definitions, IAM, the image build, the bucket lifecycle rules, and the wiring.

---

## 4. Cadence — v1 fixed loop, v2 per-unit dynamic

### v1 — fixed cron over a whole-source loop (build first)

**Cloud Scheduler (cron) → one Cloud Run Job that loops every work unit** in a
single execution. One schedule, one Job, all units at the same base cadence.
Dead simple; it's the SDK's existing whole-source run. Add a retry policy + a
failure alert and v1 is done.

### v2 — per-unit dynamic self-pacing (later)

When different units deserve different cadences (run a "hot" unit more often, a
quiet one less), split to **one self-paced invocation per unit**. Cloud Scheduler
can't take a "run again in 23s" from a worker, so the pattern is **self-pacing via
Cloud Tasks**, still triggering Jobs:

1. A run finishes for unit *U*; the service computes a recommended delay.
2. The worker enqueues a **Cloud Task with `schedule_time = now + clamp(delay)`**
   that triggers a Job execution for *U* (via a per-execution runtime override
   carrying the unit id).
3. That execution fires the next run for *U*, which enqueues the next… one
   self-propelled chain **per unit**, each paced independently.
4. A **slow Cloud Scheduler "floor"** (or catalog-refresh) run remains as a safety
   net: it re-seeds a unit whose chain died, and seeds chains for newly-appeared
   units.

Infra treats the recommended delay as an opaque number — it never inspects *why*
the service chose it.

---

## 5. Why Jobs, not a warm Service

The substrate follows the **load profile**, not a preference. These workers are
**low-volume, sporadic, sub-second tasks** with poll cadences in the minutes-to-
hours range. For that profile, scale-to-zero Jobs win on cost (no idle floor) and
simplicity (no serve layer), and their cold start is dwarfed by the poll interval.

**Tripwire — revisit if the profile changes:** if a consumer needs sub-second
freshness, in-play / real-time polling, or sustained high throughput (many
requests per *second*), a warm **Cloud Run Service** fronted by the *same* Cloud
Tasks queue becomes the better substrate (process stays warm, no per-task spawn).
That would add an HTTP serve seam in the SDK. Not needed at current cadences;
documented so the switch is a known, bounded change rather than a surprise.

---

## 6. The service → infra contract (narrow waist)

The single most important thing to get right early, so v2 needs no refactor and
every consumer uses the same channel.

**A service hands infra exactly one value per run:** a recommended delay until the
next run — `next_run_seconds: int` (or a tier `HOT | WARM | COLD` mapping to
delays). Nothing else. A service must **not** pass cron strings, queue names,
concurrency, or any operational knobs — those stay infra's.

**Infra clamps it to `[min, max]`.** The service *requests* a cadence; infra
*guarantees* it never dips below a safe floor (cost + downstream rate limits) nor
stalls above a ceiling. Intent vs. enforcement — and the floor is where infra
protects shared resources regardless of what any service asks for.

**Where each piece lives:**

- **SDK** defines the interface — a typed hint, e.g. `RunContext.request_next_run(
  delay_seconds)` or a `SchedulingHint` returned from `run()` — plus the clamp
  bounds as config. *Deferred* (declare the seam; don't build the Cloud Tasks
  emitter until v2).
- **The service** computes the delay from whatever signal it cares about.
- **Infra** owns the Cloud Tasks queue, the clamp, the Job target, IAM, and the
  floor run.

**Forward-compat:** keep cadence out of the Cloud Scheduler cron as a *source of
truth* — model it as a value that v2 will supply per unit. v1's single cron is
just the degenerate "constant delay, all units" case of the v2 mechanism.

---

## 7. Cross-cutting

- **State backend.** Terraform state in a dedicated GCS bucket (versioned,
  locked). No local state.
- **Per-service instantiation.** A reusable module (`modules/worker-job`)
  parameterized per service (image, role, env, secrets, schedule); each consumer
  is one instantiation. The module is the only place the design lives; services
  are data, not new design.
- **Config delivery.** Env vars on the Run Job; secrets via Secret Manager → env.
  The SDK reads its config from the environment, so infra's job is to populate it,
  not to know its meaning. Env-var *names* are a per-service prefix.
- **Observability.** Workers push the SDK's standard metric series at exit; infra
  provisions the metrics target and the job-failure / freshness
  (`ingestion_lag_seconds`) / breaker (`circuit_breaker_state`) alerts. Series
  names/labels are a frozen SDK surface, so dashboards are shared across consumers.
- **Environments.** At least `dev` and `prod` as separate projects or workspaces;
  same module, different vars.

---

## 8. Open decisions

- IaC tool: **Terraform** (assumed) vs Pulumi vs `gcloud` scripts. Pick in Phase 0.
- Redis: Memorystore vs skip until a service actually deploys the `latest` role.
- Metrics transport: Managed Prometheus remote-write vs a Pushgateway shim.
- v2 trigger plumbing: Cloud Tasks → Run Jobs Admin API (`jobs.run` with
  overrides) vs an intermediary — confirm when v2 is built.
