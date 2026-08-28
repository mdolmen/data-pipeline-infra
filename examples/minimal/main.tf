# Minimal, non-deployable instantiation of the pipeline module. It exists only so
# CI can exercise the modules with `terraform init -backend=false && validate` —
# real consumer roots live in the consumer's own repo (see README "Reuse from
# another project"). Values are placeholders; this is never applied.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "example-project"
  region  = "europe-west9"
}

module "pipeline" {
  source = "../../modules/pipeline"

  project_id  = "example-project"
  name_prefix = "example"
  env_prefix  = "EXAMPLE"
  image       = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"

  jobs = {
    ingest = {
      schedule = "0 * * * *"
      env      = { EXAMPLE_ROLE = "ingest" }
    }
  }
}

# Native Cloud Run Job alerts (failure + freshness) — no metrics pipeline needed.
module "observability" {
  source = "../../modules/observability"

  project_id         = "example-project"
  name_prefix        = "example"
  notification_email = "alerts@example.com"
}
