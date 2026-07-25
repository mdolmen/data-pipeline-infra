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

## What's still open

The dashboard shows live data, and the breaker/proxy alerts become buildable,
only once the **metrics backend** is provisioned and `metrics_push_gateway` is
wired on the jobs — the open decision in DESIGN §8 (Managed Prometheus
remote-write vs a Pushgateway shim; the SDK pushes via the PushGateway protocol
today). Until then, failure + freshness cover the critical gap.
