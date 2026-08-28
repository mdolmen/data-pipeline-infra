# The schedule guard. Both the Cloud Scheduler trigger and the invoker binding
# that exists solely to let the scheduler call the job hang off
# `count = var.schedule == null ? 0 : 1`. `terraform validate` never evaluates
# count, so a guard that drifted (to `== ""`, or a non-null default on
# var.schedule) would silently give every unscheduled job a cron trigger — which
# for a deliberately-paused transform job means it starts firing.
#
# Mocked provider, `command = plan`: no credentials, no API calls. Every value
# asserted here comes from configuration, so nothing depends on generated mocks.

mock_provider "google" {}

variables {
  name                            = "example-ingest"
  project                         = "example-project"
  region                          = "europe-west9"
  image                           = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  service_account_email           = "example-worker@example-project.iam.gserviceaccount.com"
  scheduler_service_account_email = "example-scheduler@example-project.iam.gserviceaccount.com"
}

run "unscheduled_job_creates_no_trigger" {
  command = plan

  variables {
    schedule = null
  }

  assert {
    condition     = length(google_cloud_scheduler_job.this) == 0
    error_message = "schedule = null must create no Cloud Scheduler job."
  }

  assert {
    condition     = length(google_cloud_run_v2_job_iam_member.invoker) == 0
    error_message = "schedule = null must not grant run.invoker to the scheduler SA."
  }
}

run "scheduled_job_creates_exactly_one_trigger" {
  command = plan

  variables {
    schedule = "0 * * * *"
  }

  assert {
    condition     = length(google_cloud_scheduler_job.this) == 1
    error_message = "A scheduled job must create exactly one Cloud Scheduler job."
  }

  assert {
    condition     = length(google_cloud_run_v2_job_iam_member.invoker) == 1
    error_message = "A scheduled job must create exactly one invoker binding."
  }
}
