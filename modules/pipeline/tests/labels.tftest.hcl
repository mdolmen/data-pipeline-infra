# Cost-attribution labels. The module merges its own dimension on top of the
# consumer's, and a merge is easy to get backwards or to drop from one resource
# while keeping it on the others — none of which `validate` sees.
#
# The per-job label is asserted in the worker-job suite instead: jobs live inside
# module.jobs here, and a test can only reach the root module of the configuration
# under test.

mock_provider "google" {}

variables {
  project_id  = "example-project"
  name_prefix = "example"
  env_prefix  = "EXAMPLE"
  image       = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  jobs        = {}
  labels      = { consumer = "example", env = "dev" }
}

run "consumer_labels_reach_every_billable_resource" {
  command = plan

  assert {
    condition     = google_artifact_registry_repository.workers.labels == var.labels
    error_message = "The registry must carry the consumer's labels."
  }

  assert {
    condition = alltrue([
      for key, value in var.labels :
      google_storage_bucket.raw.labels[key] == value && google_storage_bucket.curated.labels[key] == value
    ])
    error_message = "Both buckets must carry the consumer's labels."
  }
}

run "buckets_carry_their_tier" {
  command = plan

  assert {
    condition     = google_storage_bucket.raw.labels["tier"] == "raw" && google_storage_bucket.curated.labels["tier"] == "curated"
    error_message = "Each bucket must be labelled with its tier, so raw and curated storage cost can be told apart."
  }
}

# The derived dimension is a fact about the resource, not a default the consumer
# may shadow: a `tier` that sometimes means the bucket and sometimes means
# whatever was passed in is worse than no label at all.
run "derived_labels_win_over_consumer_labels" {
  command = plan

  variables {
    labels = { tier = "wrong", consumer = "example" }
  }

  assert {
    condition     = google_storage_bucket.raw.labels["tier"] == "raw"
    error_message = "A consumer-supplied tier must not override the bucket's own."
  }
}

run "labels_default_to_the_derived_dimension_only" {
  command = plan

  variables {
    labels = {}
  }

  assert {
    condition     = google_storage_bucket.raw.labels == tomap({ tier = "raw" })
    error_message = "With no consumer labels a bucket should still carry its tier."
  }
}

run "invalid_label_key_is_rejected" {
  command = plan

  variables {
    labels = { "Consumer" = "example" }
  }

  expect_failures = [var.labels]
}

run "invalid_label_value_is_rejected" {
  command = plan

  variables {
    labels = { consumer = "Example Inc" }
  }

  expect_failures = [var.labels]
}
