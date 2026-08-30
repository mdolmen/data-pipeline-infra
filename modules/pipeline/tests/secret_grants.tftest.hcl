# Secret-grant deduplication. Several jobs may reference the same secret, and the
# module must grant the worker SA access to it exactly once. The dedup rests
# entirely on the `toset()` in local.job_secret_ids: key the for_each by job
# instead of by secret and Terraform either errors on duplicate keys or writes two
# bindings for the same triple. `validate` sees a well-typed comprehension either
# way.

mock_provider "google" {}

variables {
  project_id  = "example-project"
  name_prefix = "example"
  env_prefix  = "EXAMPLE"
  image       = "europe-west9-docker.pkg.dev/example-project/example-workers/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  jobs        = {}
}

run "jobs_sharing_a_secret_grant_it_once" {
  command = plan

  variables {
    jobs = {
      ingest-a = {
        secret_env = { EXAMPLE_PROXY_URL = { secret = "shared-proxy-url" } }
      }
      ingest-b = {
        secret_env = { EXAMPLE_PROXY_URL = { secret = "shared-proxy-url" } }
      }
    }
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.worker_job_secrets) == 1
    error_message = "Two jobs referencing one secret must produce exactly one IAM member."
  }
}

run "distinct_secrets_each_get_a_grant" {
  command = plan

  variables {
    jobs = {
      ingest-a = {
        secret_env = { EXAMPLE_PROXY_URL = { secret = "proxy-url-a" } }
      }
      ingest-b = {
        secret_env = { EXAMPLE_PROXY_URL = { secret = "proxy-url-b" } }
      }
    }
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.worker_job_secrets) == 2
    error_message = "Two jobs referencing different secrets must produce one IAM member each."
  }
}

run "jobs_without_secrets_grant_nothing" {
  command = plan

  variables {
    jobs = {
      ingest = { env = { EXAMPLE_ROLE = "ingest" } }
    }
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.worker_job_secrets) == 0
    error_message = "A job declaring no secret_env must produce no secret IAM members."
  }
}
