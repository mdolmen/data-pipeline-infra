output "raw_bucket" {
  description = "Raw (bronze) JSONL landing bucket."
  value       = google_storage_bucket.raw.name
}

output "curated_bucket" {
  description = "Curated (lakehouse) bucket."
  value       = google_storage_bucket.curated.name
}

output "artifact_registry" {
  description = "Docker repo to push the worker image to."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.workers.repository_id}"
}

output "worker_service_account" {
  description = "Runtime SA the jobs run as."
  value       = google_service_account.worker.email
}

output "scheduler_service_account" {
  description = "SA the schedulers invoke jobs as."
  value       = google_service_account.scheduler.email
}

output "jobs" {
  description = "Deployed job names, keyed as given in var.jobs."
  value       = { for k, m in module.jobs : k => m.job_name }
}

output "injected_env" {
  description = "The SDK-standard env this module wires onto every job (each job's own env is merged on top). Lets a consumer see what its workers actually receive without reading the module."
  value       = local.injected_env
}
