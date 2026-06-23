output "raw_bucket" {
  description = "Raw (bronze) JSONL landing bucket."
  value       = module.pipeline.raw_bucket
}

output "curated_bucket" {
  description = "Curated (lakehouse) bucket."
  value       = module.pipeline.curated_bucket
}

output "artifact_registry" {
  description = "Docker repo to push the worker image to."
  value       = module.pipeline.artifact_registry
}

output "worker_service_account" {
  description = "Runtime SA for the jobs."
  value       = module.pipeline.worker_service_account
}

output "jobs" {
  description = "Deployed job names."
  value       = module.pipeline.jobs
}
