from flask import Flask, jsonify
import requests
import os
import json
from datetime import datetime
import uuid
from google.cloud import storage
import socket


app = Flask(__name__)

# Get bucket name from env variable
GCS_BUCKET = os.environ.get("GCS_BUCKET")
if not GCS_BUCKET:
    raise RuntimeError("Missing required environment variable: GCS_BUCKET")

# Create the GCS client once at startup
storage_client = storage.Client()

@app.route("/")
def ingest_api():
    url = "https://dog.ceo/api/breeds/list/all"
    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        data = response.json()
    except requests.RequestException as e:
        return jsonify({"status": "error", "message": str(e)}), 500

    filename = f"data_{datetime.utcnow().isoformat()}.json"
    with open(filename, "w") as f:
        import json
        json.dump(data, f)

    return jsonify({"status": "success", "file": filename})


@app.route("/dns-test")
def dns_test():
    try:
        ip = socket.gethostbyname("api.publicapis.org")
        return jsonify({"resolved_ip": ip})
    except Exception as e:
        return jsonify({"error": str(e)}), 500
