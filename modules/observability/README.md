# `observability` module

Alerting + the technical dashboard for SDK workers. Deliberately split by what
each piece depends on:

| Piece | Depends on | Status |
|---|---|---|
| **Job-failure alert** | Cloud Monitoring native metric | ✅ shipped here |
| **Freshness / stall alert** | Cloud Monitoring native metric | ✅ shipped here |
| **Technical dashboard** (`dashboards/technical.json`) | a Prometheus datasource | ✅ artifact shipped; deploy pending backend |
| **Breaker / proxy alerts** | SDK custom Prometheus series | ⏳ pending metrics backend (DESIGN §8) |

## Why the failure + freshness alerts need no Prometheus

Cloud Run Jobs emit `run.googleapis.com/job/completed_execution_count{result}`
to Cloud Monitoring for free. So:

- **failure** = that metric with `result="failed"` goes above 0, and
- **freshness/stall** = the `result="succeeded"` series goes *absent* for a window

…are pure Cloud Monitoring alert policies. No metrics push, no Prometheus, no
Grafana. These are the two "can't-be-backfilled" alerts, so they ship first and
work the moment a job has run at least once.

## Usage

```hcl
module "observability" {
  source = "../../modules/observability" # or a pinned git ref

  project_id         = var.project_id
  name_prefix        = var.name_prefix   # same prefix as the pipeline module
  notification_email = "you@example.com" # empty = policies with no channel
  # freshness_window_seconds = 7200      # alert if no success for 2h
}
```

`name_prefix` scopes the alerts to every Cloud Run Job named `${name_prefix}-*`,
so one instance covers `ingest-*`, `transform`, etc.

## The technical dashboard

`dashboards/technical.json` is a Grafana dashboard over the frozen SDK series
(`worker_runs_total{status}`, `records_written_total`, `bytes_written_total`,
`worker_up`): runs, in-flight (best-effort), errors, and storage, per
day/week/month via the range picker. The datasource is a **template variable**,
so it imports against any Prometheus backend.

Import it manually (Grafana → Dashboards → Import → upload the JSON, pick the
datasource), or wire the Grafana Terraform provider once the metrics backend is
chosen. It stays a versioned in-repo artifact either way (dashboards-as-JSON,
DESIGN §7).

**Counter panels use `sum_over_time()`, not `increase()`/`rate()`.** Workers are
short-lived jobs that push **one sample per run** (each run's counter starts at
0), so the counter series is sparse and non-monotonic across runs.
`increase()`/`rate()` need ≥2 samples per bucket and return *nothing* on sparse
push data — which looks like an empty panel. `sum_over_time()` sums the per-run
values, the correct aggregation for push-once counters. Don't switch them back.

## Wiring live metrics (Grafana Cloud, via OTLP)

Backend decided: **Grafana Cloud**, fed by the SDK's **OTLP/HTTP push**
(`obs/otlp_push.py`) — each worker writes its final series to Grafana Cloud's OTLP
gateway at exit, no PushGateway/scraper. (Grafana Cloud surfaces OTLP, not
Prometheus remote-write, for custom metrics.) Turn it on by setting three vars on
the **`pipeline`** module (it injects them as `${env_prefix}_METRICS_OTLP_*` and
grants the worker SA access to the token secret):

```hcl
module "pipeline" {
  # …
  metrics_otlp_url          = "https://otlp-gateway-prod-eu-central-0.grafana.net/otlp/v1/metrics"
  metrics_otlp_username     = "1737062"          # Grafana Cloud instance id
  metrics_otlp_token_secret = "grafana-otlp-token" # Secret Manager secret id
}
```

### Out-of-band steps (can't be Terraformed — external account + a secret)

1. Create a **Grafana Cloud** stack (free tier is enough). From *Connections → Add
   new connection → HTTP Metrics* (or the stack's OTLP details), copy the **OTLP
   endpoint** and **instance id** (username) and generate an **access-policy token**
   with scope `metrics:write`.
2. Put the token in **Secret Manager**: `gcloud secrets create grafana-otlp-token
   --data-file=-` (paste the token). Never in tfvars/state.
3. Set the three vars above; `terraform apply`. Workers now OTLP-push on exit.
4. In Grafana, **import `dashboards/technical.json`** and set the "Prometheus
   source" variable to your Grafana Cloud Prometheus datasource. Live within a run
   or two.

**Metric names under OTLP.** The SDK sends names exactly as Prometheus exposes
them, with no OTLP `unit`, so Grafana's OTLP→Prometheus translation keeps them
unchanged (`worker_runs_total`, `worker_up`, …) and the dashboard needs no edits.
If your stack has non-default OTLP suffix settings, check the actual names in
Grafana → Explore on the first push and align the dashboard queries if needed.

## Still backend-dependent

The **breaker/proxy alerts** (and the `ingestion_lag_seconds` freshness variant)
read the SDK's custom series, so they only become buildable once metrics are
actually flowing (step 3 above). The native failure + freshness alerts don't wait
on any of this.
