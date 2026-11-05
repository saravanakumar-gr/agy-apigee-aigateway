#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Deploy Antigravity Enterprise Gateway (agy-gateway) to Apigee X
# ==============================================================================
# Usage:
#   export PROJECT_ID="<YOUR_GCP_PROJECT_ID>"
#   export APIGEE_ENV="<YOUR_APIGEE_ENV>"
#   export APIGEE_HOST="<YOUR_APIGEE_HOSTNAME>"
#   ./deploy.sh
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "<YOUR_GCP_PROJECT_ID>")}"
APIGEE_ENV="${APIGEE_ENV:-<YOUR_APIGEE_ENV>}"
APIGEE_HOST="${APIGEE_HOST:-<YOUR_APIGEE_HOSTNAME>}"
PROXY_NAME="${PROXY_NAME:-agy-gateway}"
SA_NAME="${SA_NAME:-llm-proxy}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
PRODUCT_FILE="${PRODUCT_FILE:-${SCRIPT_DIR}/api-product.json}"
PRODUCT_NAME="$(python3 -c "import json; print(json.load(open('${PRODUCT_FILE}'))['name'])")"
DEV_EMAIL="${DEV_EMAIL:-admin@example.com}"
APP_NAME="${APP_NAME:-agy-gateway-app}"

echo "==> 1. Obtaining Google Cloud Access Token..."
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

echo "==> 2. Ensuring Target IAM Service Account (${SA_EMAIL}) exists with Vertex AI access..."
SA_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://iam.googleapis.com/v1/projects/${PROJECT_ID}/serviceAccounts/${SA_EMAIL}")
if [ "${SA_CODE}" != "200" ]; then
  echo "    Creating Service Account ${SA_EMAIL}..."
  CLOUDSDK_METRICS_ENVIRONMENT=datacloud.antigravity gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Apigee Vertex AI LLM Proxy SA" \
    --project="${PROJECT_ID}"
  CLOUDSDK_METRICS_ENVIRONMENT=datacloud.antigravity gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/aiplatform.user" \
    --condition=None >/dev/null
else
  echo "    Service Account ${SA_EMAIL} already exists."
fi

echo "==> 3. Creating Data Collectors for Analytics (DataCapture)..."
for DC in "dc_ax_model_used:STRING" "dc_tokens:INTEGER" "dc_cost_center:STRING"; do
  DC_NAME="${DC%%:*}"
  DC_TYPE="${DC##*:}"
  curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/datacollectors" \
    -d "{\"name\":\"${DC_NAME}\",\"type\":\"${DC_TYPE}\",\"description\":\"Antigravity AI Gateway Analytics (${DC_NAME})\"}" >/dev/null || true
done

echo "==> 4. Packaging ${PROXY_NAME} bundle..."
rm -f apiproxy.zip
zip -r -q apiproxy.zip apiproxy -x "*.DS_Store"

echo "==> 5. Importing ${PROXY_NAME} to Apigee Organization ${PROJECT_ID}..."
IMPORT_JSON="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
  -F "file=@apiproxy.zip" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/apis?name=${PROXY_NAME}&action=import")"
REV="$(echo "${IMPORT_JSON}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["revision"])')"
echo "    Imported Revision: ${REV}"

echo "==> 6. Deploying Revision ${REV} to environment ${APIGEE_ENV} with Service Account ${SA_EMAIL}..."
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${REV}/deployments?override=true&serviceAccount=${SA_EMAIL}" >/dev/null

echo "==> 7. Configuring API Product (${PRODUCT_NAME}) from ${PRODUCT_FILE}..."
PRODUCT_PAYLOAD="$(python3 -c "
import json
with open('${PRODUCT_FILE}') as f:
    data = json.load(f)
data['environments'] = ['${APIGEE_ENV}']
print(json.dumps(data))
")"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/apiproducts/${PRODUCT_NAME}")
if [ "${HTTP_CODE}" = "200" ]; then
  curl -s -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/apiproducts/${PRODUCT_NAME}" \
    -d "${PRODUCT_PAYLOAD}" >/dev/null
else
  curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/apiproducts" \
    -d "${PRODUCT_PAYLOAD}" >/dev/null
fi

echo "==> 8. Ensuring Developer (${DEV_EMAIL}) & Developer App (${APP_NAME}) exist..."
DEV_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/developers/${DEV_EMAIL}")
if [ "${DEV_CODE}" != "200" ]; then
  curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/developers" \
    -d "{\"email\":\"${DEV_EMAIL}\",\"firstName\":\"Antigravity\",\"lastName\":\"Admin\",\"userName\":\"agy-admin\"}" >/dev/null
fi

APP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/developers/${DEV_EMAIL}/apps/${APP_NAME}")
if [ "${APP_CODE}" != "200" ]; then
  curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/developers/${DEV_EMAIL}/apps" \
    -d "{\"name\":\"${APP_NAME}\",\"apiProducts\":[\"${PRODUCT_NAME}\"]}" >/dev/null
fi

CONSUMER_KEY=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/developers/${DEV_EMAIL}/apps/${APP_NAME}" | \
  python3 -c 'import sys,json; print(json.load(sys.stdin)["credentials"][0]["consumerKey"])')

echo "==> Deployment Complete!"
echo "    Gateway Endpoint : https://${APIGEE_HOST}/${PROXY_NAME}"
echo "    API Product      : ${PRODUCT_NAME} (configured from api-product.json)"
echo "    Developer App    : ${APP_NAME}"
echo "    Consumer API Key : ${CONSUMER_KEY}"
