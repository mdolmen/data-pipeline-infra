output "job_name" {
  description = "Cloud Run Job name."
  value       = google_cloud_run_v2_job.this.name
}

output "job_id" {
  description = "Fully-qualified Cloud Run Job id."
  value       = google_cloud_run_v2_job.this.id
}

output "scheduler_job_id" {
  description = "Cloud Scheduler job id, if a schedule was set."
  value       = try(google_cloud_scheduler_job.this[0].id, null)
}
