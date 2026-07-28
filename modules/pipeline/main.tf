# Batteries-included stack for one SDK consumer: APIs, raw + curated storage, an
# image registry, worker + scheduler identities, IAM, and N worker Jobs. A
# consumer's Terraform root calls this once with minimal config (DESIGN §7,
# README "Reuse from another project").

locals {
  apis = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudscheduler.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  raw_bucket_url     = "gs://${google_storage_bucket.raw.name}"
  curated_bucket_url = "gs://${google_storage_bucket.curated.name}"

  # SDK-standard env the module can fill because it owns the buckets. The consumer
  # only supplies business env (role, catalog url, dataset, …) per job.
  injected_env = merge(
    {
      "${var.env_prefix}_LOG_FORMAT"        = "json"
      "${var.env_prefix}_RAW_BUCKET_URL"    = local.raw_bucket_url
      "DESTINATION__FILESYSTEM__BUCKET_URL" = local.curated_bucket_url
    },
    var.metrics_otlp_url == "" ? {} : {
      "${var.env_prefix}_METRICS_OTLP_URL"      = var.metrics_otlp_url
      "${var.env_prefix}_METRICS_OTLP_USERNAME" = var.metrics_otlp_username
    },
  )

  # The OTLP token is a secret → injected from Secret Manager, not env.
  injected_secret_env = var.metrics_otlp_token_secret == "" ? {} : {
    "${var.env_prefix}_METRICS_OTLP_PASSWORD" = {
      secret  = var.metrics_otlp_token_secret
      version = "latest"
    }
  }
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- storage ---

resource "google_storage_bucket" "raw" {
  name                        = "${var.name_prefix}-${var.project_id}-raw"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  lifecycle_rule {
    condition { age = var.raw_retention_days }
    action { type = "Delete" }
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket" "curated" {
  name                        = "${var.name_prefix}-${var.project_id}-curated"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning { enabled = true }

  depends_on = [google_project_service.apis]
}

# --- image registry ---

resource "google_artifact_registry_repository" "workers" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.name_prefix}-workers"
  format        = "DOCKER"
  description   = "SDK worker images"

  depends_on = [google_project_service.apis]
}

# --- identities ---

resource "google_service_account" "worker" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-worker"
  display_name = "${var.name_prefix} worker runtime"
}

resource "google_service_account" "scheduler" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-scheduler"
  display_name = "${var.name_prefix} Cloud Scheduler → Run Job invoker"
}

resource "google_storage_bucket_iam_member" "worker_raw" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_storage_bucket_iam_member" "worker_curated" {
  bucket = google_storage_bucket.curated.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.worker.email}"
}

# Let the worker read the OTLP token secret (only when one is wired).
resource "google_secret_manager_secret_iam_member" "worker_metrics_token" {
  count = var.metrics_otlp_token_secret == "" ? 0 : 1

  project   = var.project_id
  secret_id = var.metrics_otlp_token_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"

  depends_on = [google_project_service.apis]
}

# --- jobs ---

module "jobs" {
  source   = "../worker-job"
  for_each = var.jobs

  name                  = "${var.name_prefix}-${each.key}"
  project               = var.project_id
  region                = var.region
  image                 = var.image
  service_account_email = google_service_account.worker.email

  env        = merge(local.injected_env, each.value.env)
  secret_env = local.injected_secret_env

  cpu             = each.value.cpu
  memory          = each.value.memory
  timeout_seconds = each.value.timeout_seconds
  max_retries     = each.value.max_retries

  schedule                        = each.value.schedule
  scheduler_service_account_email = google_service_account.scheduler.email
  scheduler_region                = var.scheduler_region
  time_zone                       = var.time_zone
  paused                          = each.value.paused == null ? var.schedulers_paused : each.value.paused

  depends_on = [google_project_service.apis]
}
