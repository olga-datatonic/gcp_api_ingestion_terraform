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

# BigQuery Dataset
resource "google_bigquery_dataset" "api_dataset" {
  dataset_id    = "api_ingestion_dataset"
  friendly_name = "API Ingestion Dataset"
  description   = "Dataset for storing API ingestion data from various public APIs"
  location      = var.region
  
  labels = {
    env = "production"
    team = "data-engineering"
  }
}

# Very Simple BigLake External Table
resource "google_bigquery_table" "api_ingestion_table" {
  dataset_id = google_bigquery_dataset.api_dataset.dataset_id
  table_id   = "api_data"
  
  description = "External table for API ingestion data"
  
  external_data_configuration {
    source_format = "NEWLINE_DELIMITED_JSON"
    autodetect    = true
    
    source_uris = [
      "gs://${google_storage_bucket.data_bucket.name}/*"
    ]
  }
  
  depends_on = [
    google_storage_bucket.data_bucket,
    google_bigquery_dataset.api_dataset
  ]
}

# Very Simple View - No assumptions about schema
resource "google_bigquery_table" "api_data_view" {
  dataset_id = google_bigquery_dataset.api_dataset.dataset_id
  table_id   = "api_data_view"
  
  view {
    query = <<EOF
SELECT 
  *,
  _FILE_NAME as source_file
FROM `${var.project_id}.${google_bigquery_dataset.api_dataset.dataset_id}.${google_bigquery_table.api_ingestion_table.table_id}`
LIMIT 1000
EOF
    use_legacy_sql = false
  }
  
  depends_on = [google_bigquery_table.api_ingestion_table]
}

# Keep the existing permissions (these are fine)
resource "google_project_iam_member" "bigquery_data_viewer" {
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}
