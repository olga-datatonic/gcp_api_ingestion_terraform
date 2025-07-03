from flask import Flask, jsonify, request
import requests
import os
import json
from datetime import datetime, timezone
import uuid
from google.cloud import storage
import socket
from urllib.parse import urlencode

app = Flask(__name__)

# Get bucket name from env variable
GCS_BUCKET = os.environ.get("GCS_BUCKET")
if not GCS_BUCKET:
    raise RuntimeError("Missing required environment variable: GCS_BUCKET")

# Create the GCS client once at startup
storage_client = storage.Client()

# Available APIs - Updated with working endpoints
POSTMAN_APIS = {
    "httpbin": {
        "url": "https://httpbin.org/json",
        "description": "HTTP testing service"
    },
    "jsonplaceholder": {
        "url": "https://jsonplaceholder.typicode.com/posts/1",
        "description": "Fake REST API for testing"
    },
    "reqres": {
        "url": "https://reqres.in/api/users?page=1",
        "description": "Test REST API"
    },
    "cat-facts": {
        "url": "https://catfact.ninja/fact",
        "description": "Cat facts API"
    },
    "dog-api": {
        "url": "https://dog.ceo/api/breeds/list/all",
        "description": "Dog breeds API"
    }
}

@app.route("/")
def list_apis():
    """List available APIs to ingest"""
    return jsonify({
        "status": "success",
        "message": "Available APIs for ingestion",
        "apis": POSTMAN_APIS,
        "usage": "Use /ingest/<api_name> to ingest data from a specific API"
    })

@app.route("/ingest/<api_name>")
def ingest_api(api_name):
    """Ingest data from a specific API"""
    
    if api_name not in POSTMAN_APIS:
        return jsonify({
            "status": "error", 
            "message": f"API '{api_name}' not found",
            "available_apis": list(POSTMAN_APIS.keys())
        }), 404
    
    api_config = POSTMAN_APIS[api_name]
    
    try:
        # Get additional parameters from query string
        params = request.args.to_dict()
        
        # Add more detailed logging for debugging
        print(f"Attempting to fetch from: {api_config['url']}")
        
        # Make API request with longer timeout and retries
        response = requests.get(
            api_config["url"], 
            params=params, 
            timeout=30,
            headers={
                'User-Agent': 'GCP-API-Ingestion/1.0'
            }
        )
        response.raise_for_status()
        data = response.json()
        
        print(f"Successfully fetched data from {api_name}")
        
        # Add metadata
        timestamp = datetime.now(timezone.utc)
        partition_path = f"api_name={api_name}/year={timestamp.year}/month={timestamp.month:02d}/day={timestamp.day:02d}"

        # Create a clean timestamp without problematic characters
        timestamp_str = timestamp.strftime("%Y%m%d_%H%M%S_%f")[:-3]  # YYYYMMDD_HHMMSS_mmm
        filename = f"{partition_path}/data_{timestamp_str}.json"
        
        full_data = {
            "metadata": {
                "ingestion_timestamp": timestamp.isoformat().replace('+00:00', 'Z'),
                "api_name": api_name,
                "api_url": api_config["url"],
                "api_description": api_config["description"],
                "response_status": response.status_code,
                "request_params": params if params else {}
            },
            "data": data
        }
        
    except requests.exceptions.RequestException as e:
        print(f"Request failed for {api_name}: {str(e)}")
        return jsonify({
            "status": "error", 
            "message": f"Failed to fetch data from {api_name}: {str(e)}",
            "api_url": api_config["url"],
            "suggestion": "Try a different API or check network connectivity"
        }), 500
    except Exception as e:
        print(f"Unexpected error for {api_name}: {str(e)}")
        return jsonify({
            "status": "error", 
            "message": f"Unexpected error: {str(e)}"
        }), 500

    try:
        # Test JSON serialization
        json_str = json.dumps(full_data, indent=2, ensure_ascii=False)
        
        bucket = storage_client.bucket(GCS_BUCKET)
        blob = bucket.blob(filename)
        blob.upload_from_string(json_str, content_type='application/json')
        
        return jsonify({
            "status": "success",
            "api_name": api_name,
            "file": filename,
            "gcs_path": f"gs://{GCS_BUCKET}/{filename}",
            "records_ingested": len(data) if isinstance(data, list) else 1,
            "ingestion_timestamp": full_data["metadata"]["ingestion_timestamp"]
        })
        
    except (TypeError, ValueError) as json_error:
        print(f"JSON serialization error: {json_error}")
        return jsonify({
            "status": "error", 
            "message": f"JSON serialization failed: {str(json_error)}"
        }), 500

@app.route("/ingest-all")
def ingest_all_apis():
    """Ingest data from all available APIs"""
    results = []
    
    for api_name in POSTMAN_APIS.keys():
        try:
            # This is a simplified approach - in production, you'd want to handle this differently
            # to avoid timeout issues with multiple API calls
            result = ingest_api(api_name)
            results.append({
                "api_name": api_name,
                "status": "success" if result[1] == 200 else "error",
                "result": result[0].get_json() if hasattr(result[0], 'get_json') else str(result[0])
            })
        except Exception as e:
            results.append({
                "api_name": api_name,
                "status": "error",
                "error": str(e)
            })
    
    return jsonify({
        "status": "completed",
        "message": "Bulk ingestion completed",
        "results": results
    })

@app.route("/health")
def health_check():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "gcs_bucket": GCS_BUCKET
    })

@app.route("/dns-test")
def dns_test():
    """DNS test endpoint"""
    try:
        ip = socket.gethostbyname("api.publicapis.org")
        return jsonify({"resolved_ip": ip})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/test-connectivity")
def test_connectivity():
    """Test connectivity to various APIs"""
    results = {}
    
    for api_name, api_config in POSTMAN_APIS.items():
        try:
            response = requests.get(api_config["url"], timeout=10)
            results[api_name] = {
                "status": "success",
                "status_code": response.status_code,
                "response_time": response.elapsed.total_seconds()
            }
        except Exception as e:
            results[api_name] = {
                "status": "error",
                "error": str(e)
            }
    
    return jsonify({
        "connectivity_test": results,
        "timestamp": datetime.now(timezone.utc).isoformat()
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
