# GCP API Ingestion Pipeline Documentation

## Overview

This project implements a complete data ingestion pipeline on Google Cloud Platform that extracts data from multiple REST APIs, stores it in Cloud Storage with Hive partitioning, and enables querying through BigQuery. The pipeline includes both incremental and backfill capabilities orchestrated through Cloud Workflows.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   External APIs │    │   Cloud Run     │    │   Cloud Storage │
│                 │ -> │   Service       │ -> │   (Hive         │
│ • HTTPBin       │    │   (Python)      │    │   Partitioned)  │
│ • Dog API       │    │                 │    │                 │
│ • Cat Facts     │    │                 │    │                 │
│ • JSONPlaceholder│   │                 │    │                 │
│ • ReqRes        │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                       │
┌─────────────────┐    ┌─────────────────┐           │
│ Cloud Workflows │    │ BigQuery/       │ <─────────┘
│                 │    │ BigLake Table   │
│ • Incremental   │    │                 │
│ • Backfill      │    │                 │
└─────────────────┘    └─────────────────┘
```

## Components

### 1. Cloud Run Service (API Ingestion)

**File:** `cloudrun/main.py`

**Purpose:** Serves as the main data ingestion service that fetches data from multiple REST APIs and stores it in Cloud Storage with Hive partitioning.

**Implementation Details:**

```python
# Key Features:
- Multi-API support (5 different Postman APIs)
- Hive partitioning structure: api_name=X/year=Y/month=Z/day=W/
- Clean timestamp formatting for filenames
- Comprehensive error handling
- GCS upload with proper metadata
```

**API Endpoints:**
- `GET /` - Health check
- `POST /ingest/<api_name>` - Trigger ingestion for specific API
- `GET /test-connectivity` - Test all API endpoints

**Hive Partitioning Structure:**
```
gs://bucket/api_name=httpbin/year=2025/month=01/day=15/data_20250115_143022_123.json
```

### 2. Containerization (Docker)

**File:** `cloudrun/Dockerfile`

**Implementation:**
```dockerfile
FROM python:3.9-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8080
CMD ["python", "main.py"]
```

**Key Design Decisions:**
- Lightweight python:3.9-slim base image
- Layer caching optimization (requirements.txt first)
- Single application file for simplicity

### 3. Infrastructure as Code (Terraform)

**File:** `main.tf`

**Components Deployed:**

#### 3.1 Cloud Storage Bucket
```hcl
resource "google_storage_bucket" "data_bucket" {
  name          = "run-sources-${var.project_id}-${var.region}"
  location      = var.region
  force_destroy = true
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}
```

#### 3.2 Cloud Run Service
```hcl
resource "google_cloud_run_service" "api_ingest" {
  name     = "api-ingest"
  location = var.region
  
  template {
    spec {
      containers {
        image = "gcr.io/${var.project_id}/api-ingest:latest"
        
        env {
          name  = "GCS_BUCKET"
          value = google_storage_bucket.data_bucket.name
        }
        
        resources {
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }
      }
    }
  }
}
```

#### 3.3 Service Account & IAM
```hcl
resource "google_service_account" "cloud_run_sa" {
  account_id   = "cloud-run-sa"
  display_name = "Cloud Run Service Account"
}

resource "google_storage_bucket_iam_member" "cloud_run_gcs_writer" {
  bucket = google_storage_bucket.data_bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}
```

#### 3.4 BigQuery Dataset & Table
```hcl
resource "google_bigquery_dataset" "api_dataset" {
  dataset_id    = "api_ingestion_dataset"
  friendly_name = "API Ingestion Dataset"
  description   = "Dataset for storing API ingestion data"
  location      = var.region
  
  default_table_expiration_ms = 7776000000  # 90 days
}

resource "google_bigquery_table" "api_ingestion_table" {
  dataset_id = google_bigquery_dataset.api_dataset.dataset_id
  table_id   = "api_data"
  
  external_data_configuration {
    source_format = "NEWLINE_DELIMITED_JSON"
    autodetect    = true
    ignore_unknown_values = true
    max_bad_records      = 1000
    
    source_uris = [
      "gs://${google_storage_bucket.data_bucket.name}/api_name=*/year=*/month=*/day=*/*.json"
    ]
    
    hive_partitioning_options {
      mode              = "AUTO"
      source_uri_prefix = "gs://${google_storage_bucket.data_bucket.name}/"
    }
  }
}
```

### 4. Cloud Workflows

#### 4.1 Incremental Ingestion Workflow

**File:** `workflows/incremental_ingest.yaml`

**Purpose:** Orchestrates regular data ingestion from multiple APIs

**Implementation:**
```yaml
main:
  steps:
    - log_start:
        call: sys.log
        args:
          data: "Starting incremental API ingestion"
          severity: INFO
    
    - call_httpbin:
        try:
          call: http.post
          args:
            url: "https://api-ingest-424zvnon7q-ew.a.run.app/ingest/httpbin"
            timeout: 60
        except:
          as: e
          steps:
            - log_httpbin_error:
                call: sys.log
                args:
                  data: "Error ingesting httpbin"
                  severity: ERROR
    # ... similar blocks for other APIs
```

**Key Features:**
- Sequential API calls (safer than parallel)
- Individual error handling per API
- Comprehensive logging
- Timeout protection

#### 4.2 Backfill Workflow

**File:** `workflows/backfill.yaml`

**Purpose:** Processes historical data for specific APIs and date ranges

**Implementation:**
```yaml
main:
  params: [args]
  steps:
    - set_defaults:
        assign:
          - target_api: ${default(args.api_name, "httpbin")}
    
    - call_api:
        try:
          call: http.post
          args:
            url: '${"https://api-ingest-424zvnon7q-ew.a.run.app/ingest/" + target_api}'
            query:
              backfill_date: ${args.start_date}
            timeout: 60
```

**Usage:**
```bash
gcloud workflows run api-data-backfill --location=europe-west1 --data='{"start_date":"2025-07-01","end_date":"2025-07-02","api_name":"httpbin"}'
```

## Step-by-Step Implementation

### Phase 1: Basic Cloud Run Service
1. **Created Python Flask application** with basic API ingestion
2. **Implemented GCS upload functionality** using google-cloud-storage
3. **Created Dockerfile** for containerization
4. **Set up Terraform** for infrastructure deployment

### Phase 2: Multi-API Support
1. **Added 5 Postman APIs** to the service
2. **Implemented flexible routing** with `/ingest/<api_name>` pattern
3. **Added error handling** for each API endpoint
4. **Created connectivity testing** endpoint

### Phase 3: Hive Partitioning
1. **Implemented date-based partitioning** structure
2. **Fixed timestamp formatting** to avoid special characters
3. **Created clean filename generation** for BigQuery compatibility
4. **Added metadata** to JSON files for better tracking

### Phase 4: BigQuery Integration
1. **Created BigQuery dataset** and external table
2. **Configured Hive partitioning** for automatic partition detection
3. **Added error handling** for malformed JSON files
4. **Implemented flexible schema** detection

### Phase 5: Cloud Workflows
1. **Created incremental workflow** for regular ingestion
2. **Built backfill workflow** for historical data processing
3. **Fixed Cloud Workflows syntax** issues (for loops, parameters)
4. **Added comprehensive error handling** and logging

## Key Technical Decisions

### 1. Cloud Run Service vs Cloud Functions
**Decision:** Used Cloud Run Service
**Reasoning:** 
- More flexible for HTTP endpoints
- Better for multi-API architecture
- Easier container management
- More suitable for complex applications

### 2. Hive Partitioning Strategy
**Decision:** `api_name=X/year=Y/month=Z/day=W/`
**Reasoning:**
- Optimal for time-based queries
- Efficient for BigQuery partition pruning
- Logical separation by API source
- Supports incremental processing

### 3. Simplified Cloud Workflows
**Decision:** Sequential API calls instead of parallel loops
**Reasoning:**
- Cloud Workflows syntax limitations
- Easier error handling
- More reliable execution
- Simpler debugging

### 4. Error Handling Strategy
**Decision:** Graceful degradation with logging
**Reasoning:**
- Don't fail entire pipeline for single API issues
- Comprehensive logging for debugging
- Retry mechanisms where appropriate
- Monitoring-friendly approach

## Deployment Instructions

### Prerequisites
```bash
# Install required tools
gcloud auth login
gcloud config set project dt-emea-pod-hopper-05-dev
terraform init
```

### Deploy Infrastructure
```bash
# Deploy all resources
terraform plan
terraform apply

# Build and deploy container
gcloud builds submit --tag gcr.io/dt-emea-pod-hopper-05-dev/api-ingest:latest cloudrun/
```

### Test the Pipeline
```bash
# Test incremental ingestion
curl -X POST https://api-ingest-424zvnon7q-ew.a.run.app/ingest/httpbin

# Test workflow
gcloud workflows run incremental-api-ingest --location=europe-west1

# Query data in BigQuery
bq query --use_legacy_sql=false 'SELECT * FROM `dt-emea-pod-hopper-05-dev.api_ingestion_dataset.api_data` LIMIT 10'
```

## Troubleshooting Guide

### Common Issues

#### 1. JSON Parsing Errors in BigQuery
**Problem:** `JSON parsing error: Expected key`
**Solution:** 
- Clean up malformed files in GCS
- Regenerate data with fixed timestamp format
- Increase `max_bad_records` in BigQuery table

#### 2. Cloud Workflows Syntax Errors
**Problem:** `parse error: missing 'steps'`
**Solution:**
- Ensure proper YAML indentation
- Use single parameter `args` instead of multiple
- Quote all dynamic expressions

#### 3. Permission Errors
**Problem:** `Access denied` when writing to GCS
**Solution:**
- Verify service account has `storage.objectCreator` role
- Check Cloud Run service is using correct service account
- Ensure APIs are enabled

#### 4. Container Build Failures
**Problem:** Docker build fails
**Solution:**
- Check Dockerfile syntax
- Verify all required files are present
- Ensure requirements.txt has correct dependencies

## Monitoring & Observability

### Cloud Logging
- **Cloud Run logs:** Application-level logging
- **Workflow logs:** Execution status and errors
- **BigQuery logs:** Query performance and errors

### Key Metrics to Monitor
- **API response times** for each external service
- **GCS upload success rates**
- **BigQuery query performance**
- **Workflow execution frequency and success**

### Alerting Recommendations
- **API failures** > 10% error rate
- **GCS upload failures**
- **Workflow execution failures**
- **BigQuery query errors**

## Performance Considerations

### Scalability
- **Cloud Run:** Auto-scales based on request volume
- **BigQuery:** Handles large datasets efficiently with partitioning
- **GCS:** Virtually unlimited storage capacity

### Cost Optimization
- **Lifecycle policies** on GCS bucket (90-day retention)
- **BigQuery slot optimization** through partitioning
- **Cloud Run minimum instances** set to 0 for cost savings

### Data Freshness
- **Incremental workflow:** Can be scheduled hourly
- **Real-time processing:** Trigger via HTTP requests
- **Backfill capability:** Process historical data as needed

## Future Enhancements

### 1. Advanced Scheduling
```hcl
resource "google_cloud_scheduler_job" "incremental_schedule" {
  name     = "incremental-api-ingest"
  schedule = "0 * * * *"  # Every hour
  
  http_target {
    uri = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/workflows/incremental-api-ingest/executions"
  }
}
```

### 2. Data Quality Monitoring
- Schema validation
- Data freshness checks
- Anomaly detection
- Data lineage tracking

### 3. Advanced Workflows
- Parallel processing with proper error handling
- Complex date range processing
- Conditional logic based on data patterns
- Integration with other GCP services

### 4. Security Enhancements
- API key management with Secret Manager
- VPC network restrictions
- Advanced IAM policies
- Audit logging

## Conclusion

This implementation provides a robust, scalable, and cost-effective solution for API data ingestion on Google Cloud Platform. The architecture supports both real-time and batch processing patterns while maintaining high availability and comprehensive monitoring capabilities.

The modular design allows for easy extension with additional APIs, enhanced workflows, and advanced data processing capabilities as requirements evolve. 

## 🚀 **Use GET Requests to Generate Fresh Data**

### **Complete Working Commands**

```bash
# Get service URL
SERVICE_URL=$(gcloud run services describe api-ingest --region=europe-west1 --format="value(status.url)")
echo "Service URL: $SERVICE_URL"

# Generate fresh data using GET requests
echo "Generating fresh data..."

curl $SERVICE_URL/ingest/httpbin
echo "HTTPBin data generated"
sleep 3

curl $SERVICE_URL/ingest/dog-api
echo "Dog API data generated"
sleep 3

curl $SERVICE_URL/ingest/cat-facts
echo "Cat Facts data generated"
sleep 3

curl $SERVICE_URL/ingest/jsonplaceholder
echo "JSONPlaceholder data generated"
sleep 3

curl $SERVICE_URL/ingest/reqres
echo "ReqRes data generated"
sleep 3

echo "All fresh data generated!"
```

### **Verify Data Structure**

```bash
# Check the new files were created
gcloud storage ls gs://run-sources-dt-emea-pod-hopper-05-dev-europe-west1/api_name=*/year=*/month=*/day=*/*.json
```

### **Test BigQuery**

```bash
# Wait for BigQuery to detect the new files
echo "Waiting for BigQuery to refresh..."
sleep 60

# Test the query
bq query --use_legacy_sql=false 'SELECT COUNT(*) as total_records FROM `dt-emea-pod-hopper-05-dev.api_ingestion_dataset.api_data`'
```

## 🎯 **All Commands in One Block**

Copy and paste this entire block:

```bash
# Get service URL
SERVICE_URL=$(gcloud run services describe api-ingest --region=europe-west1 --format="value(status.url)")
echo "Service URL: $SERVICE_URL"

# Generate fresh data using GET requests
curl $SERVICE_URL/ingest/httpbin
sleep 3
curl $SERVICE_URL/ingest/dog-api
sleep 3
curl $SERVICE_URL/ingest/cat-facts
sleep 3
curl $SERVICE_URL/ingest/jsonplaceholder
sleep 3
curl $SERVICE_URL/ingest/reqres
sleep 3

# Verify data structure
echo "Checking file structure..."
gcloud storage ls gs://run-sources-dt-emea-pod-hopper-05-dev-europe-west1/api_name=*/year=*/month=*/day=*/*.json

# Test BigQuery
echo "Waiting for BigQuery to refresh..."
sleep 60
bq query --use_legacy_sql=false 'SELECT COUNT(*) as total_records FROM `dt-emea-pod-hopper-05-dev.api_ingestion_dataset.api_data`'
```

## 🔧 **Update Your Workflows Too**

Since your workflows are using POST requests, you'll need to update them to use GET requests:

```python
@app.route("/ingest/<api_name>")  # This defaults to GET method only
def ingest_api(api_name):
``` 
