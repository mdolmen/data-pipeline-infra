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
  description = "Runtime SA for the jobs."
  value       = google_service_account.worker.email
}

output "ingest_job" {
  value = module.ingest_job.job_name
}

output "transform_job" {
  value = module.transform_job.job_name
}
