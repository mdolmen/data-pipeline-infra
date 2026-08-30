# Bucket IAM asymmetry: raw is append-only for the worker, curated keeps
# objectAdmin. The asymmetry is the point — raw cannot be rebuilt, curated can be
# replayed from it. Each grant is one string, so a "tidy-up" that unified them
# would look like an improvement while silently handing the runtime SA delete on
# raw. These runs make that a failing test rather than a review someone must catch.

mock_provider "google" {}

variables {
  project_id  = "example-project"
  name_prefix = "example"
  env_prefix  = "EXAMPLE"
  image       = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  jobs        = {}
}

run "raw_grants_create_and_read_but_not_delete" {
  command = plan

  assert {
    condition = toset([for m in google_storage_bucket_iam_member.worker_raw : m.role]) == toset([
      "roles/storage.objectCreator",
      "roles/storage.objectViewer",
    ])
    error_message = "The worker's raw-bucket grant must be exactly objectCreator + objectViewer — objectAdmin would let the runtime SA delete un-backfillable raw data."
  }

  # Stated as its own assertion because it is the specific regression that matters:
  # any role carrying storage.objects.delete on raw defeats the whole change.
  assert {
    condition     = !contains([for m in google_storage_bucket_iam_member.worker_raw : m.role], "roles/storage.objectAdmin")
    error_message = "objectAdmin must never be granted on the raw bucket."
  }
}

run "curated_keeps_object_admin" {
  command = plan

  assert {
    condition     = google_storage_bucket_iam_member.worker_curated.role == "roles/storage.objectAdmin"
    error_message = "Curated must keep objectAdmin — the Delta merge rewrites and deletes files there."
  }
}

# The only run here that isn't `command = plan`. The SA email is provider-computed,
# so it is unknown during a plan and the condition below cannot evaluate; on the
# pinned 1.9.5 an `override_resource` doesn't help either, because overrides land at
# apply time and `override_during` (which would move them into the plan) only exists
# from a later Terraform. `apply` against a mock provider stays entirely offline —
# no credentials, no cloud calls — so this costs nothing but the deviation.
run "both_grants_target_the_worker_identity" {
  command = apply

  override_resource {
    target = google_service_account.worker
    values = {
      email = "example-worker@example-project.iam.gserviceaccount.com"
    }
  }

  assert {
    condition = alltrue([
      for m in concat(
        [for r in google_storage_bucket_iam_member.worker_raw : r.member],
        [google_storage_bucket_iam_member.worker_curated.member],
      ) : m == "serviceAccount:${google_service_account.worker.email}"
    ])
    error_message = "Bucket grants must go to the worker SA, not the scheduler SA."
  }
}
