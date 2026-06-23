# data-pipeline-infra

A **Terraform module library** for deploying `data-pipeline-core` workers to GCP —
the deploy-side analogue of the SDK. It owns the *generic* substrate (Cloud Run
Jobs, storage, registry, identities, scheduling); it has **no consumer specifics**.
See [DESIGN.md](DESIGN.md) for the architecture and [TODO.md](TODO.md) for the
build plan.

Each consuming project keeps its own thin Terraform root **in its own repo** and
imports these modules — mirroring how each consumer imports the Python SDK. (The
first consumer, `proba-markets-analysis`, has its root at `infra/dev/` in that
repo; its deploy runbook lives there too.)

## Layout

```
modules/
  worker-job/      one Cloud Run Job (+ optional cron + IAM) — granular
  pipeline/        batteries-included stack: storage + registry + identities + IAM + N jobs
examples/
  minimal/         non-deployable fixture so CI can validate the modules
```

`modules/pipeline` is the reusable entrypoint — a consumer gets the whole stack by
calling it with minimal config. `modules/worker-job` stays for hand-composition.

## Reuse from another project

A new consumer (e.g. `airbnb-intel`) keeps its own thin root and imports `pipeline`:

```hcl
# airbnb-intel/infra/dev/main.tf
module "pipeline" {
  source      = "git::https://github.com/<you>/data-pipeline-infra.git//modules/pipeline?ref=v1.0.0"
  project_id  = var.project_id
  name_prefix = "airbnb"
  image       = var.image
  env_prefix  = "AIRBNB"   # SDK-standard env (RAW_BUCKET_URL, …) is auto-wired under this

  jobs = {
    ingest    = { schedule = "0 * * * *",  env = { AIRBNB_ROLE = "ingest",    AIRBNB_CATALOG_URL = "…" } }
    transform = { schedule = "20 * * * *", env = { AIRBNB_ROLE = "transform", AIRBNB_DATASET = "stays" } }
  }
}
```

Minimal config = `project_id`, `name_prefix`, `image`, `env_prefix`, and the
`jobs` map. The consumer also supplies its own `backend.tf` + `provider` block
(Terraform can't abstract those into a module) and a `terraform.tfvars`. Use
`proba-markets-analysis/infra/dev/` as the full worked example.

**Versioning.** Pin `?ref=` to a tag (`git tag v0.1.0`). During co-development,
point `source` at a local path (`../../../data-pipeline-infra/modules/pipeline`),
the same editable trick as the SDK — swap to a pinned ref once the API stabilises.

## What the consumer provides vs what the module wires

| Consumer supplies | Module wires automatically |
|---|---|
| `project_id`, `name_prefix`, `image`, `env_prefix` | raw + curated GCS buckets (raw has a retention TTL) |
| per-job business env (`*_ROLE`, catalog url, dataset, …) | `${env_prefix}_RAW_BUCKET_URL`, dlt `DESTINATION__…`, `*_LOG_FORMAT` |
| per-job `schedule` (cron) | the Cloud Run Job, the Scheduler trigger, and the IAM to invoke it |
| `backend.tf` + `provider` + `tfvars` (per Terraform) | Artifact Registry repo, worker + scheduler service accounts, APIs |

## Notes

- **Secrets.** Not required by the module. `worker-job` exposes a `secret_env`
  input (name → Secret Manager secret) for consumers that need one (proxy creds,
  Redis URL); GCS access is via the worker SA, not a secret.
- **Cost.** Jobs scale to zero — you pay only per execution (seconds). See
  DESIGN §5.
- **First apply is two-step** (registry must exist + image pushed before the jobs
  are created); the consumer's runbook covers the ordering.
