# Remote state in GCS. The state bucket is bootstrapped out-of-band (see README),
# then passed at init time so it isn't itself managed by this state:
#   terraform init -backend-config="bucket=<your-tf-state-bucket>"
terraform {
  backend "gcs" {
    prefix = "data-pipeline/dev"
  }
}
