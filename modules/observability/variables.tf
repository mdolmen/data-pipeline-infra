variable "project_id" {
  description = "GCP project id the alert policies live in."
  type        = string
}

variable "name_prefix" {
  description = "Job-name prefix to scope the alerts (matches the pipeline module's name_prefix, e.g. \"pma\"). Alerts watch every Cloud Run Job whose name starts with it."
  type        = string
}

variable "notification_email" {
  description = "Email address for an alert notification channel. Empty string = create the alert policies with no channel wired (they still fire in the console; add channels later)."
  type        = string
  default     = ""
}

variable "freshness_window_seconds" {
  description = "How long with no *successful* execution before the freshness/stall alert fires. Default 2h — a gap in the hoard is the one thing that can't be backfilled, so alert well before the daily loss matters."
  type        = number
  default     = 7200
}

variable "failure_alignment_period_seconds" {
  description = "Window over which failed executions are counted for the failure alert. A single failed execution in this window trips it."
  type        = number
  default     = 300
}

variable "enable_failure_alert" {
  description = "Create the job-failure alert policy."
  type        = bool
  default     = true
}

variable "enable_freshness_alert" {
  description = "Create the freshness/stall (absence-of-success) alert policy."
  type        = bool
  default     = true
}
