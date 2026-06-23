# dev environment for proba-markets-analysis — a thin root over the reusable
# `pipeline` module. This is also the worked example a new consumer copies:
# fill project_id + image, declare the jobs, done. (DESIGN §7, README.)

module "pipeline" {
  source = "../../modules/pipeline"

  project_id         = var.project_id
  region             = var.region
  name_prefix        = var.name_prefix
  image              = var.image
  env_prefix         = "PMA"
  raw_retention_days = var.raw_retention_days
  schedulers_paused  = var.schedulers_paused

  # RAW_BUCKET_URL / DESTINATION__FILESYSTEM__BUCKET_URL / LOG_FORMAT are wired by
  # the module; jobs only carry business env.
  jobs = {
    ingest = {
      schedule = var.ingest_schedule
      env = {
        PMA_ROLE          = "ingest"
        PMA_INGEST_OUTPUT = "raw"
        PMA_CATALOG_URL   = var.catalog_url
        PMA_IMPERSONATE   = var.impersonate
      }
    }
    transform = {
      schedule = var.transform_schedule
      env = {
        PMA_ROLE             = "transform"
        PMA_TRANSFORM_OUTPUT = "curated"
        PMA_DATASET          = var.dataset
        PMA_DESTINATION      = "filesystem"
        PMA_IMPERSONATE      = var.impersonate
      }
    }
  }
}
