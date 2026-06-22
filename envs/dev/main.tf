# dev environment: enable APIs, provision storage + image registry + identities,
# and deploy the v1 jobs — a whole-source ingest loop (hourly) and a transform
# job. Substrate is Cloud Run Jobs throughout (DESIGN §2/§5).

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

  # Shared across roles.
  base_env = {
    PMA_LOG_FORMAT     = "json"
    PMA_IMPERSONATE    = var.impersonate
    PMA_RAW_BUCKET_URL = local.raw_bucket_url
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
  display_name = "Data-pipeline worker runtime"
}

resource "google_service_account" "scheduler" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-scheduler"
  display_name = "Cloud Scheduler → Run Job invoker"
}

# Worker reads/writes its buckets only.
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

# --- jobs ---

module "ingest_job" {
  source = "../../modules/worker-job"

  name                  = "${var.name_prefix}-ingest"
  project               = var.project_id
  region                = var.region
  image                 = var.image
  service_account_email = google_service_account.worker.email

  # Whole-source loop: no PMA_MAX_COMPETITIONS → all competitions in one run.
  env = merge(local.base_env, {
    PMA_ROLE          = "ingest"
    PMA_INGEST_OUTPUT = "raw"
    PMA_CATALOG_URL   = var.catalog_url
  })

  schedule                        = var.ingest_schedule
  scheduler_service_account_email = google_service_account.scheduler.email
  paused                          = var.schedulers_paused

  depends_on = [google_project_service.apis]
}

module "transform_job" {
  source = "../../modules/worker-job"

  name                  = "${var.name_prefix}-transform"
  project               = var.project_id
  region                = var.region
  image                 = var.image
  service_account_email = google_service_account.worker.email

  env = merge(local.base_env, {
    PMA_ROLE             = "transform"
    PMA_TRANSFORM_OUTPUT = "curated"
    PMA_DATASET          = var.dataset
    PMA_DESTINATION      = "filesystem"
    # dlt's own env for the filesystem destination (curated lakehouse).
    DESTINATION__FILESYSTEM__BUCKET_URL = local.curated_bucket_url
  })

  schedule                        = var.transform_schedule
  scheduler_service_account_email = google_service_account.scheduler.email
  paused                          = var.schedulers_paused

  depends_on = [google_project_service.apis]
}
