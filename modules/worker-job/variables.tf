variable "name" {
  description = "Cloud Run Job name (e.g. pma-ingest)."
  type        = string
}

variable "project" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "GCP region for the job and its scheduler."
  type        = string
}

variable "image" {
  description = "Fully-qualified worker image, pinned by digest (…@sha256:…)."
  type        = string
}

variable "service_account_email" {
  description = "Runtime service account the job runs as (writes to GCS, reads secrets)."
  type        = string
}

variable "env" {
  description = "Plain environment variables for the worker (e.g. PMA_ROLE)."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Secret-backed env vars: name => { secret = <secret id>, version = <version> }."
  type = map(object({
    secret  = string
    version = optional(string, "latest")
  }))
  default = {}
}

variable "cpu" {
  description = "vCPU limit per task."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory limit per task."
  type        = string
  default     = "512Mi"
}

variable "timeout_seconds" {
  description = "Max wall-clock for one execution."
  type        = number
  default     = 600
}

variable "max_retries" {
  description = "Task retries before the execution is marked failed."
  type        = number
  default     = 1
}

# Scheduling (v1). Leave schedule null to create the job without a trigger
# (e.g. a job driven later by Cloud Tasks in v2).
variable "schedule" {
  description = "Cron for a Cloud Scheduler trigger; null = no schedule."
  type        = string
  default     = null
}

variable "scheduler_region" {
  description = "Region for the Cloud Scheduler resource. Defaults to var.region; override when the job's region isn't a Cloud Scheduler location (e.g. europe-west9 → europe-west1). The trigger still calls the job in var.region."
  type        = string
  default     = null
}

variable "time_zone" {
  description = "Scheduler time zone."
  type        = string
  default     = "Europe/Paris"
}

variable "scheduler_service_account_email" {
  description = "SA the scheduler authenticates as to invoke the job (needs run.invoker). Required when schedule is set."
  type        = string
  default     = null
}

variable "paused" {
  description = "Create the scheduler in PAUSED state (deploy without firing yet)."
  type        = bool
  default     = false
}
