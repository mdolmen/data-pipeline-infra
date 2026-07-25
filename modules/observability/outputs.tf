output "notification_channel_id" {
  description = "Email notification channel id, if an address was given."
  value       = try(google_monitoring_notification_channel.email[0].id, null)
}

output "alert_policy_ids" {
  description = "Created alert-policy ids, keyed by kind."
  value = {
    job_failed   = try(google_monitoring_alert_policy.job_failed[0].id, null)
    ingest_stall = try(google_monitoring_alert_policy.ingest_stall[0].id, null)
  }
}
