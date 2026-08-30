variable "name" {
  description = "Cloud Run Job name."
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

  # The docs promise a digest and build.sh resolves one; enforcing it here is what
  # keeps a job spec reproducible — a tag silently re-points under a running job.
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest, ending in @sha256:<64 hex chars>."
  }
}

variable "service_account_email" {
  description = "Runtime service account the job runs as (writes to GCS, reads secrets)."
  type        = string
}

variable "env" {
  description = "Plain environment variables for the worker."
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

variable "labels" {
  description = "Labels applied to the Cloud Run Job, for cost attribution in the billing export."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for key, value in var.labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", key)) && can(regex("^[a-z0-9_-]{0,63}$", value))
    ])
    error_message = "Label keys must start with a lowercase letter, and keys and values may hold only lowercase letters, digits, - and _, up to 63 characters."
  }
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

  # Without it the scheduler resource still plans, then fails at apply with an
  # IAM error that doesn't mention this input.
  validation {
    condition     = var.schedule == null || (var.scheduler_service_account_email != null && var.scheduler_service_account_email != "")
    error_message = "scheduler_service_account_email is required when schedule is set — the trigger needs an identity with run.invoker."
  }
}

variable "paused" {
  description = "Create the scheduler in PAUSED state (deploy without firing yet)."
  type        = bool
  default     = false
}
