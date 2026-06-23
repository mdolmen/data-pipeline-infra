variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "GCP region for all resources."
  type        = string
  default     = "europe-west9"
}

variable "name_prefix" {
  description = "Prefix for resource names (buckets, SAs, jobs). Often the consumer slug."
  type        = string
}

variable "image" {
  description = "Worker image pinned by digest (…@sha256:…). Built and pushed out of band."
  type        = string
}

variable "env_prefix" {
  description = "The consumer's env-var prefix (e.g. PMA, AIRBNB). The module auto-wires the SDK-standard env (RAW_BUCKET_URL, LOG_FORMAT) under this prefix; jobs supply the rest."
  type        = string
}

variable "raw_retention_days" {
  description = "Lifecycle TTL on the raw (bronze) bucket. Keep generous — the hoard can't be backfilled."
  type        = number
  default     = 30
}

variable "jobs" {
  description = <<-EOT
    Workers to deploy, keyed by short name (e.g. ingest, transform). Each:
      env             — business env vars (role, catalog url, dataset, …). The
                        module merges in the SDK-standard env automatically.
      schedule        — cron for a Cloud Scheduler trigger; null = no schedule.
      cpu/memory      — task resource limits.
      timeout_seconds — max wall-clock per execution.
      max_retries     — task retries before the execution fails.
      paused          — override schedulers_paused for this job (null = inherit).
  EOT
  type = map(object({
    env             = optional(map(string), {})
    schedule        = optional(string)
    cpu             = optional(string, "1")
    memory          = optional(string, "512Mi")
    timeout_seconds = optional(number, 600)
    max_retries     = optional(number, 1)
    paused          = optional(bool)
  }))
}

variable "time_zone" {
  description = "Scheduler time zone."
  type        = string
  default     = "Europe/Paris"
}

variable "schedulers_paused" {
  description = "Default PAUSED state for all schedulers (per-job overridable). Deploy paused, flip to false to go live."
  type        = bool
  default     = true
}
