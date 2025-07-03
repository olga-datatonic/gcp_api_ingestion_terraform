output "cloud_run_url" {
  value = google_cloud_run_service.api_ingest.status[0].url
}

output "bigquery_dataset_id" {
  value = google_bigquery_dataset.api_dataset.dataset_id
  description = "BigQuery dataset ID for API ingestion"
}

output "bigquery_table_id" {
  value = google_bigquery_table.api_ingestion_table.table_id
  description = "BigQuery table ID for API ingestion data"
}

output "bigquery_table_full_name" {
  value = "${var.project_id}.${google_bigquery_dataset.api_dataset.dataset_id}.${google_bigquery_table.api_ingestion_table.table_id}"
  description = "Full BigQuery table name"
}

output "bigquery_view_full_name" {
  value = "${var.project_id}.${google_bigquery_dataset.api_dataset.dataset_id}.${google_bigquery_table.api_data_view.table_id}"
  description = "Full BigQuery view name for easier querying"
}
