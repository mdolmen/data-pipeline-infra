# Alerting over Cloud Run Jobs, built on Cloud Monitoring's *native* execution
# metric — no Prometheus pipeline required. Cloud Run Jobs emit
# `run.googleapis.com/job/completed_execution_count{result}` for free, so the two
# alerts that matter most (a run failed; a run *stopped happening*) need nothing
# from the SDK metrics push. The Prometheus-backed alerts (breaker, proxy) and the
# live technical dashboard depend on the metrics backend (DESIGN §8), still open.
#
# Scope: every Cloud Run Job whose name starts with var.name_prefix, so one module
# instance covers all of a consumer's jobs (ingest-*, transform, …).

locals {
  job_prefix_filter = "resource.labels.job_name = starts_with(\"${var.name_prefix}-\")"

  base_filter = join(" AND ", [
    "resource.type = \"cloud_run_job\"",
    "metric.type = \"run.googleapis.com/job/completed_execution_count\"",
    local.job_prefix_filter,
  ])
}

# Email channel. Optional: with no address the policies are created channel-less
# (still visible/firing in the console) and channels can be attached later.
resource "google_monitoring_notification_channel" "email" {
  count = var.notification_email == "" ? 0 : 1

  project      = var.project_id
  display_name = "${var.name_prefix} alerts email"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }
}

# A watched Job execution finished with result=failed. Cloud Run already retries a
# task up to max_retries; this fires when the *execution* is ultimately failed.
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

# Freshness / silent-stall: no *successful* execution for the whole watched fleet
# within the window. This is the alert that guards the un-backfillable gap — if
# collection quietly stops (egress block, bad deploy, paused scheduler), the
# success series goes absent and this fires even though nothing "errored".
resource "google_monitoring_alert_policy" "ingest_stall" {
  count = var.enable_freshness_alert ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix} — no successful run (stall)"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "No successful ${var.name_prefix} execution in ${var.freshness_window_seconds}s"
    condition_absent {
      filter   = "${local.base_filter} AND metric.labels.result = \"succeeded\""
      duration = "${var.freshness_window_seconds}s"

      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.email[*].id

  documentation {
    content   = "No ${var.name_prefix} Cloud Run Job has completed successfully in the last ${var.freshness_window_seconds}s. Collection may have silently stalled (egress block, failed deploy, paused scheduler). A gap in the raw hoard cannot be backfilled — investigate now."
    mime_type = "text/markdown"
  }
}
