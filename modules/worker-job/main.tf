# A single SDK worker, deployed as a one-shot Cloud Run Job, optionally triggered
# on a fixed cron. The job runs `python -m workers.main`; behaviour is selected
# entirely by env (PMA_ROLE etc.) — see DESIGN.md §2.

resource "google_cloud_run_v2_job" "this" {
  name                = var.name
  location            = var.region
  project             = var.project
  deletion_protection = false

  template {
    template {
      service_account = var.service_account_email
      timeout         = "${var.timeout_seconds}s"
      max_retries     = var.max_retries

      containers {
        image = var.image

        resources {
          limits = {
            cpu    = var.cpu
            memory = var.memory
          }
        }

        dynamic "env" {
          for_each = var.env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value.secret
                version = env.value.version
              }
            }
          }
        }
      }
    }
  }
}

# Allow the scheduler's SA to invoke this specific job.
resource "google_cloud_run_v2_job_iam_member" "invoker" {
  count = var.schedule == null ? 0 : 1

  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_job.this.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.scheduler_service_account_email}"
}

# Fixed-cadence trigger (v1). Calls the Run Admin API jobs:run endpoint — a Google
# API, so OAuth (not OIDC). This is the "constant delay, all units" degenerate
# case of the v2 per-unit Cloud Tasks mechanism (DESIGN §4/§6).
resource "google_cloud_scheduler_job" "this" {
  count = var.schedule == null ? 0 : 1

  name             = "${var.name}-trigger"
  project          = var.project
  region           = var.region
  schedule         = var.schedule
  time_zone        = var.time_zone
  attempt_deadline = "320s"
  paused           = var.paused

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project}/locations/${var.region}/jobs/${google_cloud_run_v2_job.this.name}:run"

    oauth_token {
      service_account_email = var.scheduler_service_account_email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.invoker]
}
