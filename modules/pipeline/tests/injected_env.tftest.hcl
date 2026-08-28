# The env the module fills in on the consumer's behalf, and the OTLP switch.
#
# injected_env is the module's core promise — it owns the buckets, so it wires the
# bucket env — and every key is built from ${var.env_prefix}. Hard-code that prefix
# and every consumer but the one it was hard-coded for silently loses its raw
# bucket, with no type error to show for it.
#
# OTLP is one feature with three inputs, gated by a single local.otlp_enabled and
# validated as all-or-nothing. Both halves are asserted here: the off state emits
# no env and no IAM grant, and the half-configured states are rejected at plan
# time rather than failing quietly in production (a url without credentials pushes
# nothing, and the SDK swallows push failures by design).

mock_provider "google" {}

variables {
  project_id  = "example-project"
  name_prefix = "example"
  env_prefix  = "EXAMPLE"
  image       = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  jobs = {
    ingest = { env = { EXAMPLE_ROLE = "ingest" } }
  }
}

run "injected_env_is_built_from_the_consumer_prefix" {
  command = plan

  assert {
    condition     = output.injected_env["EXAMPLE_RAW_BUCKET_URL"] == "gs://example-example-project-raw"
    error_message = "injected_env must carry ${var.env_prefix}_RAW_BUCKET_URL pointing at the module's raw bucket."
  }

  assert {
    condition     = output.injected_env["EXAMPLE_LOG_FORMAT"] == "json"
    error_message = "injected_env must carry ${var.env_prefix}_LOG_FORMAT."
  }
}

run "otlp_off_emits_no_env_and_no_grant" {
  command = plan

  assert {
    condition     = !contains(keys(output.injected_env), "EXAMPLE_METRICS_OTLP_URL")
    error_message = "With no OTLP url, no OTLP env may be injected."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.worker_metrics_token) == 0
    error_message = "With OTLP off, the worker SA must get no secretAccessor grant."
  }
}

run "otlp_on_emits_env_and_exactly_one_grant" {
  command = plan

  variables {
    metrics_otlp_url          = "https://otlp-gateway.example.net/otlp/v1/metrics"
    metrics_otlp_username     = "1737062"
    metrics_otlp_token_secret = "otlp-token"
  }

  assert {
    condition     = output.injected_env["EXAMPLE_METRICS_OTLP_URL"] == "https://otlp-gateway.example.net/otlp/v1/metrics"
    error_message = "With OTLP on, the url must be injected under the consumer prefix."
  }

  assert {
    condition     = output.injected_env["EXAMPLE_METRICS_OTLP_USERNAME"] == "1737062"
    error_message = "With OTLP on, the basic-auth username must be injected."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.worker_metrics_token) == 1
    error_message = "With OTLP on, the worker SA needs exactly one secretAccessor grant for the token."
  }
}

# The three half-configured states. Each was representable before the inputs were
# validated as a set, and each failed quietly: a url without credentials pushes
# nothing to an authenticated gateway, and credentials without a url leave a
# secretAccessor grant on a switched-off feature.

run "url_without_credentials_is_rejected" {
  command = plan

  variables {
    metrics_otlp_url = "https://otlp-gateway.example.net/otlp/v1/metrics"
  }

  expect_failures = [var.metrics_otlp_url]
}

run "url_and_username_without_token_is_rejected" {
  command = plan

  variables {
    metrics_otlp_url      = "https://otlp-gateway.example.net/otlp/v1/metrics"
    metrics_otlp_username = "1737062"
  }

  expect_failures = [var.metrics_otlp_url]
}

run "token_without_url_is_rejected" {
  command = plan

  variables {
    metrics_otlp_token_secret = "otlp-token"
  }

  expect_failures = [var.metrics_otlp_url]
}
