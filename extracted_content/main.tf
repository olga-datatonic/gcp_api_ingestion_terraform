terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.0"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "bigquery" {
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "workflows" {
  service            = "workflows.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "workflow_executions" {
  service            = "workflowexecutions.googleapis.com"
  disable_on_destroy = false
}

# Create GCS Bucket for raw data landing
resource "google_storage_bucket" "data_bucket" {
  name                        = var.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
}

# Service Account for Cloud Run
resource "google_service_account" "cloud_run_sa" {
  account_id   = "cloud-run-sa"
  display_name = "Cloud Run service account"
}

# Grant Cloud Run SA permission to write to GCS bucket
resource "google_storage_bucket_iam_member" "bucket_writer" {
  bucket = google_storage_bucket.data_bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Grant Cloud Run SA permissions to invoke workflows
resource "google_project_iam_member" "workflow_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# (Optional) Grant Cloud Run service agent role if needed
resource "google_project_iam_member" "cloud_run_service_agent" {
  project = var.project_id
  role    = "roles/run.serviceAgent"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Cloud Run service deploying your container image
resource "google_cloud_run_service" "api_ingest" {
  name     = "api-ingest"
  location = var.region

  template {
    spec {
      service_account_name = google_service_account.cloud_run_sa.email
      containers {
        image = var.cloud_run_image
        resources {
          limits = {
            memory = "2Gi"
            cpu    = "1000m"
          }
        }
        env {
          name  = "GCS_BUCKET"
          value = google_storage_bucket.data_bucket.name
        }
      }
      container_concurrency = 80
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

# Allow unauthenticated invocations (optional, for public API)
resource "google_cloud_run_service_iam_member" "invoker" {
  location = google_cloud_run_service.api_ingest.location
  project  = var.project_id
  service  = google_cloud_run_service.api_ingest.name
  role     = "roles/run.invoker"
  member   = "allUsers"  # Change to specific user or group for restricted access
}
