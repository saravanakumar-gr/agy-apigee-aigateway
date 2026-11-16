#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Provision Employee Developers, Custom Attributes (x-cost-center) & API Keys
# ==============================================================================
# Reads developers.json, creates/updates each employee as an Apigee Developer
# with their x-cost-center custom attribute, creates their unique Developer App,
# and outputs each employee's unique Antigravity Consumer API Key.
#
# Usage:
#   export PROJECT_ID="<YOUR_GCP_PROJECT_ID>"
#   ./provision-developers.sh [path/to/developers.json]
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "<YOUR_GCP_PROJECT_ID>")}"
DEVELOPERS_FILE="${1:-${DEVELOPERS_FILE:-${SCRIPT_DIR}/developers.json}}"
DEFAULT_PRODUCT="${PRODUCT_NAME:-agy-gateway-product}"

if [[ "${PROJECT_ID}" == "<YOUR_GCP_PROJECT_ID>" ]]; then
  echo "Error: Please export PROJECT_ID before running ./provision-developers.sh"
  exit 1
fi

if [ ! -f "${DEVELOPERS_FILE}" ]; then
  echo "Error: Developers file not found at ${DEVELOPERS_FILE}"
  exit 1
fi

if [ -z "${TOKEN:-}" ]; then
  if [ -f "${HOME}/.config/gcloud/application_default_credentials.json" ]; then
    TOKEN="$(python3 -c '
import json, os, urllib.request, urllib.parse
adc_path = os.path.expanduser("~/.config/gcloud/application_default_credentials.json")
with open(adc_path) as f:
    creds = json.load(f)
data = urllib.parse.urlencode({
    "client_id": creds["client_id"],
    "client_secret": creds["client_secret"],
    "refresh_token": creds["refresh_token"],
    "grant_type": "refresh_token"
}).encode()
req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
with urllib.request.urlopen(req) as resp:
    print(json.loads(resp.read())["access_token"])
')"
  else
    TOKEN="$(CLOUDSDK_METRICS_ENVIRONMENT=datacloud.antigravity gcloud auth application-default print-access-token)"
  fi
fi

PROJECT_ID="${PROJECT_ID}" TOKEN="${TOKEN}" DEVELOPERS_FILE="${DEVELOPERS_FILE}" DEFAULT_PRODUCT="${DEFAULT_PRODUCT}" python3 - <<'PYEOF'
import json
import os
import urllib.error
import urllib.parse
import urllib.request

project_id = os.environ["PROJECT_ID"]
token = os.environ["TOKEN"]
dev_file = os.environ["DEVELOPERS_FILE"]
default_product = os.environ["DEFAULT_PRODUCT"]

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}
base_url = f"https://apigee.googleapis.com/v1/organizations/{project_id}"

with open(dev_file) as f:
    config = json.load(f)

developers = config.get("developers", [])
if not developers:
    raise SystemExit(f"No developers defined in {dev_file}")

for dev in developers:
    email = dev["email"]
    first_name = dev.get("firstName", "Employee")
    last_name = dev.get("lastName", "User")
    user_name = dev.get("userName", email.split("@")[0].replace(".", "-"))
    attributes = dev.get("attributes", [])
    app_name = dev.get("appName", f"agy-key-{user_name}")
    api_products = dev.get("apiProducts", [default_product])

    email_enc = urllib.parse.quote(email, safe="@")
    dev_url = f"{base_url}/developers/{email_enc}"

    # 1. Create or update Developer (employee) & custom attributes (x-cost-center)
    dev_payload = {
        "email": email,
        "firstName": first_name,
        "lastName": last_name,
        "userName": user_name,
        "attributes": attributes,
    }
    try:
        with urllib.request.urlopen(urllib.request.Request(dev_url, headers=headers)) as r:
            existing = json.loads(r.read())
        merged_attrs = {a["name"]: a["value"] for a in existing.get("attributes", [])}
        for a in attributes:
            merged_attrs[a["name"]] = a["value"]
        dev_payload["attributes"] = [{"name": k, "value": v} for k, v in merged_attrs.items()]
        urllib.request.urlopen(
            urllib.request.Request(dev_url, data=json.dumps(dev_payload).encode(), headers=headers, method="PUT")
        ).read()
        action = "Updated"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            urllib.request.urlopen(
                urllib.request.Request(f"{base_url}/developers", data=json.dumps(dev_payload).encode(), headers=headers, method="POST")
            ).read()
            action = "Created"
        else:
            raise

    # 2. Ensure Developer App (unique employee API key) exists & is linked to API Product(s)
    app_enc = urllib.parse.quote(app_name, safe="")
    app_url = f"{base_url}/developers/{email_enc}/apps/{app_enc}"
    try:
        with urllib.request.urlopen(urllib.request.Request(app_url, headers=headers)) as r:
            app_data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            create_app_payload = {
                "name": app_name,
                "apiProducts": api_products,
            }
            with urllib.request.urlopen(
                urllib.request.Request(f"{base_url}/developers/{email_enc}/apps", data=json.dumps(create_app_payload).encode(), headers=headers, method="POST")
            ) as r:
                app_data = json.loads(r.read())
        else:
            raise

    consumer_key = app_data["credentials"][0]["consumerKey"]
    cost_center = next((a["value"] for a in dev_payload["attributes"] if a["name"] == "x-cost-center"), "Unassigned")
    print(f"    [{action}] Employee : {email}")
    print(f"              Cost Ctr : {cost_center} (Developer attribute: x-cost-center)")
    print(f"              App Name : {app_name} -> Products: {', '.join(api_products)}")
    print(f"              API Key  : {consumer_key}")
PYEOF
