# Input guards for the standalone primitive. The pipeline module always supplies a
# scheduler identity, so this pairing only goes wrong for a consumer composing
# worker-job by hand — which is exactly the case the module exists to support.

mock_provider "google" {}

variables {
  name                  = "example-ingest"
  project               = "example-project"
  region                = "europe-west9"
  image                 = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  service_account_email = "example-worker@example-project.iam.gserviceaccount.com"
}

run "unscheduled_job_needs_no_scheduler_identity" {
  command = plan
}

run "scheduled_job_without_a_scheduler_identity_is_rejected" {
  command = plan

  variables {
    schedule = "0 * * * *"
  }

  expect_failures = [var.scheduler_service_account_email]
}

# Empty string counts as missing: it plans, then fails at apply on an IAM member
# with no principal.
run "scheduled_job_with_an_empty_scheduler_identity_is_rejected" {
  command = plan

  variables {
    schedule                        = "0 * * * *"
    scheduler_service_account_email = ""
  }

  expect_failures = [var.scheduler_service_account_email]
}

run "scheduled_job_with_a_scheduler_identity_plans" {
  command = plan

  variables {
    schedule                        = "0 * * * *"
    scheduler_service_account_email = "example-scheduler@example-project.iam.gserviceaccount.com"
  }
}

run "tagged_image_is_rejected" {
  command = plan

  variables {
    image = "europe-west9-docker.pkg.dev/example-project/example-workers/worker:latest"
  }

  expect_failures = [var.image]
}
