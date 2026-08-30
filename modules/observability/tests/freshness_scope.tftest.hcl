# The freshness alert's scope and grouping. Both are one line each in main.tf and
# both fail silently when wrong: drop the grouping and one healthy job hides every
# other, mistype a watched job and the condition watches a series that never
# existed. Neither shows up as a broken plan.

mock_provider "google" {}

variables {
  project_id  = "example-project"
  name_prefix = "example"
}

run "freshness_groups_by_job_name" {
  command = plan

  assert {
    condition     = google_monitoring_alert_policy.ingest_stall[0].conditions[0].condition_absent[0].aggregations[0].group_by_fields == tolist(["resource.label.job_name"])
    error_message = "The freshness alert must group by job name, or one healthy job suppresses it for every other."
  }
}

run "unset_watched_jobs_covers_the_whole_prefix" {
  command = plan

  assert {
    condition     = strcontains(google_monitoring_alert_policy.ingest_stall[0].conditions[0].condition_absent[0].filter, "starts_with(\"example-\")")
    error_message = "With watched_jobs unset the freshness alert must fall back to the name_prefix filter."
  }

  assert {
    condition     = strcontains(google_monitoring_alert_policy.ingest_stall[0].conditions[0].condition_absent[0].filter, "metric.labels.result = \"succeeded\"")
    error_message = "The freshness alert must watch the succeeded series."
  }
}

run "watched_jobs_narrows_the_filter" {
  command = plan

  variables {
    watched_jobs = ["example-ingest-a", "example-ingest-b"]
  }

  assert {
    condition     = strcontains(google_monitoring_alert_policy.ingest_stall[0].conditions[0].condition_absent[0].filter, "one_of(\"example-ingest-a\",\"example-ingest-b\")")
    error_message = "watched_jobs must narrow the freshness filter to exactly those jobs."
  }

  # The narrowing is deliberately asymmetric: a parked job never fails, so
  # excluding it from freshness must not exclude it from failure alerting.
  assert {
    condition     = strcontains(google_monitoring_alert_policy.job_failed[0].conditions[0].condition_threshold[0].filter, "starts_with(\"example-\")")
    error_message = "watched_jobs must not narrow the failure alert."
  }
}

run "watched_job_outside_the_prefix_is_rejected" {
  command = plan

  variables {
    watched_jobs = ["other-ingest-a"]
  }

  expect_failures = [var.watched_jobs]
}
