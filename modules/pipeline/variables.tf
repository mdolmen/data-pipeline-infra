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

# --- metrics OTLP push (→ an OTLP backend, e.g. Grafana Cloud's OTLP gateway) ---
# Set the url to turn on OTLP push on every job. The SDK writes its final series
# to this endpoint at exit (preferred over a PushGateway for short-lived jobs).
# Injected as ${env_prefix}_METRICS_OTLP_{URL,USERNAME,PASSWORD}.
#
# The three are one feature and are validated as all-or-nothing, because each
# half-configured state fails quietly:
#   url without credentials — the SDK sends no Authorization header, the gateway
#     rejects the push, and push failures are swallowed by design (observability
#     must not break ingestion). It surfaces as a permanently empty dashboard on
#     a worker that reports success, which is the worst way to lose metrics.
#   credentials without a url — the SDK never takes the OTLP branch at all, so
#     the injected password is dead env and the secretAccessor grant is standing
#     privilege on a feature that is switched off.
# An unauthenticated OTLP collector is therefore not supported: from the module's
# inputs it is indistinguishable from a forgotten token. Relax this if a consumer
# ever actually needs one.

variable "metrics_otlp_url" {
  description = "OTLP/HTTP metrics endpoint (e.g. https://otlp-gateway-<zone>.grafana.net/otlp/v1/metrics). Empty = OTLP off (jobs fall back to metrics_push_gateway / no push)."
  type        = string
  default     = ""

  validation {
    condition = alltrue([
      for value in [
        var.metrics_otlp_url,
        var.metrics_otlp_username,
        var.metrics_otlp_token_secret,
      ] : (value == "") == (var.metrics_otlp_url == "")
    ])
    error_message = "OTLP is all-or-nothing: set metrics_otlp_url, metrics_otlp_username and metrics_otlp_token_secret together, or leave all three empty."
  }
}

variable "metrics_otlp_username" {
  description = "Basic-auth username for OTLP (Grafana Cloud: the numeric instance id). Non-secret. Required when metrics_otlp_url is set."
  type        = string
  default     = ""
}

variable "metrics_otlp_token_secret" {
  description = "Secret Manager secret id holding the OTLP API token (the basic-auth password). Required when metrics_otlp_url is set. Create the secret out of band; never put the token in tfvars/state."
  type        = string
  default     = ""
}

variable "jobs" {
  description = <<-EOT
    Workers to deploy, keyed by short name (e.g. ingest, transform). Each:
      env             — business env vars (role, catalog url, dataset, …). The
                        module merges in the SDK-standard env automatically.
      secret_env      — env vars backed by Secret Manager, for values that must
                        not sit in plain env (proxy credentials, API keys):
                        NAME => { secret = <secret id>, version = <version> }.
                        The secret must exist; the module grants the worker SA
                        read access to it.
      schedule        — cron for a Cloud Scheduler trigger; null = no schedule.
      cpu/memory      — task resource limits.
      timeout_seconds — max wall-clock per execution.
      max_retries     — task retries before the execution fails.
      paused          — override schedulers_paused for this job (null = inherit).
  EOT
  type = map(object({
    env = optional(map(string), {})
    secret_env = optional(map(object({
      secret  = string
      version = optional(string, "latest")
    })), {})
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

variable "scheduler_region" {
  description = "Region for Cloud Scheduler. Defaults to var.region; override when region isn't a Scheduler location (e.g. europe-west9 → europe-west1)."
  type        = string
  default     = null
}

variable "schedulers_paused" {
  description = "Default PAUSED state for all schedulers (per-job overridable). Deploy paused, flip to false to go live."
  type        = bool
  default     = true
}
