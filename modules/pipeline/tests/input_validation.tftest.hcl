# Input guards that move an apply-time GCP error to plan time. Each of these
# otherwise fails only once some resources already exist, with a message naming a
# derived id rather than the input that produced it.

mock_provider "google" {}

variables {
  project_id  = "example-project"
  name_prefix = "example"
  env_prefix  = "EXAMPLE"
  image       = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  jobs        = {}
}

run "valid_inputs_plan" {
  command = plan
}

# 21 chars: "-scheduler" takes it to 31, one over the service account id limit.
run "name_prefix_over_twenty_chars_is_rejected" {
  command = plan

  variables {
    name_prefix = "abcdefghijklmnopqrstu"
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_at_twenty_chars_is_accepted" {
  command = plan

  variables {
    name_prefix = "abcdefghijklmnopqrst"
  }
}

# The likely mistake: passing the upper-case env_prefix value here.
run "uppercase_name_prefix_is_rejected" {
  command = plan

  variables {
    name_prefix = "EXAMPLE"
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_with_trailing_hyphen_is_rejected" {
  command = plan

  variables {
    name_prefix = "example-"
  }

  expect_failures = [var.name_prefix]
}

run "tagged_image_is_rejected" {
  command = plan

  variables {
    image = "europe-west9-docker.pkg.dev/example-project/example-workers/worker:latest"
  }

  expect_failures = [var.image]
}

# A digest-shaped suffix that isn't 64 hex chars would still be rejected by the
# registry, just much later.
run "truncated_digest_is_rejected" {
  command = plan

  variables {
    image = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000"
  }

  expect_failures = [var.image]
}
