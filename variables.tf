variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "dt-emea-pod-hopper-05-dev"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "bucket_name" {
  description = "GCS bucket name"
  type        = string
  default     = "run-sources-dt-emea-pod-hopper-05-dev-europe-west1"
}

variable "cloud_run_image" {
  description = "Container image URL for Cloud Run service"
  type        = string
  default     = "gcr.io/dt-emea-pod-hopper-05-dev/api-ingest:latest"
}
