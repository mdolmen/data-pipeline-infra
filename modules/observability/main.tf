# Cloud Monitoring alerts over the native Cloud Run metric
# `run.googleapis.com/job/completed_execution_count{result}`, which the platform
# emits for free — a run failed, and a run stopped happening, without a metrics
# pipeline. Scope: Jobs named `${name_prefix}-*`.

locals {
  job_prefix_filter = "resource.labels.job_name = starts_with(\"${var.name_prefix}-\")"

  metric_selector = [
    "resource.type = \"cloud_run_job\"",
    "metric.type = \"run.googleapis.com/job/completed_execution_count\"",
  ]

  base_filter = join(" AND ", concat(local.metric_selector, [local.job_prefix_filter]))

  # Freshness asks whether a job stopped running, and a paused job stopped on
  # purpose. Nothing observable separates "parked" from "silently dead", so the
  # jobs that must stay fresh are named explicitly.
  watched_jobs_filter = "resource.labels.job_name = one_of(${join(",", [for job in var.watched_jobs : "\"${job}\""])})"

  freshness_filter = join(" AND ", concat(local.metric_selector, [
    length(var.watched_jobs) > 0 ? local.watched_jobs_filter : local.job_prefix_filter,
    "metric.labels.result = \"succeeded\"",
  ]))
}

# Optional: with no address the policies are created channel-less (still visible
# in the console) and channels can be attached later.
resource "google_monitoring_notification_channel" "email" {
  count = var.notification_email == "" ? 0 : 1

  project      = var.project_id
  display_name = "${var.name_prefix} alerts email"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }
}

# Cloud Run already retries a task up to max_retries; this fires when the
# *execution* is ultimately failed.
resource "google_monitoring_alert_policy" "job_failed" {
  count = var.enable_failure_alert ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix} — worker job failed"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "A ${var.name_prefix} job execution failed"
    condition_threshold {
      filter          = "${local.base_filter} AND metric.labels.result = \"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "${var.failure_alignment_period_seconds}s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.job_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.email[*].id

  documentation {
    content   = "A ${var.name_prefix} Cloud Run Job execution failed. Check the job logs; a run is idempotent so a manual re-run is safe, but investigate before the next scheduled tick."
    mime_type = "text/markdown"
  }
}

# Silent stall: no *successful* execution within the window. Guards the gap that
# can't be backfilled — collection stopping without anything "erroring".
resource "google_monitoring_alert_policy" "ingest_stall" {
  count = var.enable_freshness_alert ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix} — no successful run (stall)"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "A watched ${var.name_prefix} job has no successful execution in ${var.freshness_window_seconds}s"
    condition_absent {
      filter   = local.freshness_filter
      duration = "${var.freshness_window_seconds}s"

      # Per job. Without the grouping the reducer collapses every job into one
      # series, and one healthy job suppresses the alert for all the others.
      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.job_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.email[*].id

  documentation {
    content   = "A watched ${var.name_prefix} Cloud Run Job has not completed successfully in the last ${var.freshness_window_seconds}s. Collection may have silently stalled (blocked egress, failed deploy, paused scheduler). Raw data for that window cannot be backfilled — investigate now."
    mime_type = "text/markdown"
  }
}
