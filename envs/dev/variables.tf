variable "project_id" {
  description = "GCP project id for this environment."
  type        = string
}

variable "region" {
  description = "GCP region. Paris by default — closest egress to the FR target (see README on egress IP / geo-fencing)."
  type        = string
  default     = "europe-west9"
}

variable "name_prefix" {
  description = "Prefix for resource names (buckets, SAs, jobs)."
  type        = string
  default     = "pma"
}

variable "image" {
  description = "Worker image pinned by digest (region-docker.pkg.dev/…/worker@sha256:…). Built and pushed out of band (see README)."
  type        = string
}

# --- worker config (consumer-specific; passed through as PMA_* env) ---

variable "catalog_url" {
  description = "Betclic football catalog page (drives the competition list)."
  type        = string
  default     = "https://www.betclic.fr/football-sfootball"
}

variable "impersonate" {
  description = "Browser-TLS profile for the SDK HTTP client."
  type        = string
  default     = "firefox"
}

variable "dataset" {
  description = "Curated dataset name (transform output)."
  type        = string
  default     = "betting"
}

# --- storage ---

variable "raw_retention_days" {
  description = "Lifecycle TTL on the raw (bronze) bucket. Keep generous — the hoard can't be backfilled."
  type        = number
  default     = 30
}

# --- cadence (v1) ---

variable "ingest_schedule" {
  description = "Cron for the whole-source ingest loop (base 1/hour)."
  type        = string
  default     = "0 * * * *"
}

variable "transform_schedule" {
  description = "Cron for the transform job (offset from ingest)."
  type        = string
  default     = "20 * * * *"
}

variable "schedulers_paused" {
  description = "Deploy schedulers PAUSED so nothing fires until you verify a manual run. Flip to false to go live."
  type        = bool
  default     = true
}
