# data-pipeline-infra

Terraform for deploying `data-pipeline-core` workers to GCP. See
[DESIGN.md](DESIGN.md) for the architecture and [TODO.md](TODO.md) for the build
plan. **v1** = a whole-source ingest Job on an hourly cron landing raw to GCS,
plus a transform Job → curated.

## Layout

```
modules/worker-job/   reusable: one Cloud Run Job (+ optional cron + IAM)
envs/dev/             one environment: storage, registry, identities, the jobs
```

`envs/dev/main.tf` provisions the shared infra and instantiates `worker-job`
twice (ingest, transform). A new environment is the same modules with a different
`terraform.tfvars` and project.

## Prerequisites

- `terraform >= 1.5`, `gcloud`, Docker.
- A GCP project with billing enabled, and `gcloud auth application-default login`.

## 1. Bootstrap the state bucket (one-time, manual)

Terraform state lives in GCS, but the bucket can't be managed by the state it
holds — create it by hand once:

```bash
gcloud storage buckets create gs://<your-tf-state-bucket> \
  --project <project> --location europe-west9 --uniform-bucket-level-access
gcloud storage buckets update gs://<your-tf-state-bucket> --versioning
```

## 2. Build & push the worker image

The worker depends on the SDK via an editable path, so the build context must
contain **both** repos as siblings. From the parent directory that holds
`proba-markets-analysis/` and `data-pipeline-core/`:

```bash
REPO=europe-west9-docker.pkg.dev/<project>/pma-workers
gcloud auth configure-docker europe-west9-docker.pkg.dev

docker build -f proba-markets-analysis/Dockerfile -t $REPO/worker:$(git -C proba-markets-analysis rev-parse --short HEAD) .
docker push $REPO/worker:<tag>
```

> The Artifact Registry repo (`pma-workers`) is created by Terraform (step 4),
> so on the very first run either push after `apply`, or create the repo first.
> Pin the **digest** (`worker@sha256:…`) into `terraform.tfvars`, not a tag.

## 3. Configure

```bash
cd envs/dev
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, image (the @sha256 digest)
```

## 4. Init / plan / apply

```bash
terraform init -backend-config="bucket=<your-tf-state-bucket>"
terraform plan
terraform apply
```

Schedulers deploy **paused** (`schedulers_paused = true`), so nothing fires yet.

## 5. Verify, then go live

```bash
# one manual run of the whole-source loop
gcloud run jobs execute pma-ingest --region europe-west9 --project <project>
# confirm raw JSONL landed
gcloud storage ls gs://pma-<project>-raw/

# happy? unpause the crons:
#   set schedulers_paused = false in terraform.tfvars, then:
terraform apply
```

## Notes

- **Egress IP / geo-fencing.** Betclic is FR-facing and fingerprints clients.
  Cloud Run's egress IP is a Google IP that may not geolocate to FR, so the
  region (`europe-west9`, Paris) reduces latency but does **not** guarantee an FR
  egress IP. If Betclic geo-blocks the Cloud Run IP, route egress through a static
  FR IP (Cloud NAT) or the SDK proxy. Verify with the step-5 manual run before
  unpausing.
- **Secrets.** v1 needs none (Betclic is anonymous; GCS auth is via the worker
  SA). The module supports `secret_env` for when one is needed (proxy creds,
  Redis URL).
- **Cost.** Jobs scale to zero; you pay only per execution (seconds). See
  DESIGN §5.
