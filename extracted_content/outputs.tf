output "cloud_run_url" {
  value = google_cloud_run_service.api_ingest.status[0].url
}
