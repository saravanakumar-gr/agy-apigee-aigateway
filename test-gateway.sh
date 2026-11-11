#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Automated Verification Suite for Antigravity Apigee Enterprise Gateway
# ==============================================================================
# Usage:
#   export AGY_LLM_GATEWAY_URL="https://<YOUR_APIGEE_HOSTNAME>/agy-gateway"
#   export AGY_LLM_GATEWAY_API_KEY="<YOUR_APIGEE_CONSUMER_KEY>"
#   ./test-gateway.sh
# ==============================================================================

GATEWAY_URL="${AGY_LLM_GATEWAY_URL:-https://<YOUR_APIGEE_HOSTNAME>/agy-gateway}"
API_KEY="${AGY_LLM_GATEWAY_API_KEY:-}"
COST_CENTER="${COST_CENTER:-Platform-Engineering}"

if [ -z "${API_KEY}" ] && [ -f "admin_settings.json" ]; then
  API_KEY="$(python3 -c 'import json; print(json.load(open("admin_settings.json"))["gateway"]["apiKey"])')"
fi

if [ -z "${API_KEY}" ]; then
  echo "Error: Please set AGY_LLM_GATEWAY_API_KEY or ensure admin_settings.json exists."
  exit 1
fi

echo "=============================================================================="
echo "Testing Antigravity Apigee Enterprise Gateway: ${GATEWAY_URL}"
echo "=============================================================================="

echo ""
echo "==> Test 1: Unauthenticated Request (Expect HTTP 401 from VerifyAPIKey)"
CODE_1=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GATEWAY_URL}/v1beta/models/gemini-3.8-flash:generateContent" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Reply with PONG"}]}]}')
echo "    HTTP Status: ${CODE_1}"
if [ "${CODE_1}" = "401" ]; then
  echo "    [PASS] Unauthenticated request rejected with 401."
else
  echo "    [FAIL] Expected 401, got ${CODE_1}."
  exit 1
fi

echo ""
echo "==> Test 2: IDE Telemetry Endpoint (POST /v1beta:recordTelemetry -> Expect HTTP 200 {})"
CODE_2=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GATEWAY_URL}/v1beta:recordTelemetry" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"events":[]}')
echo "    HTTP Status: ${CODE_2}"
if [ "${CODE_2}" = "200" ]; then
  echo "    [PASS] Telemetry endpoint acknowledged with 200 OK."
else
  echo "    [FAIL] Expected 200, got ${CODE_2}."
  exit 1
fi

echo ""
echo "==> Test 3: Unapproved Model Rejection (gemini-1.5-flash -> Expect Rejection)"
RES_3=$(curl -s -X POST \
  "${GATEWAY_URL}/v1beta/models/gemini-1.5-flash:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "X-Cost-Center: ${COST_CENTER}" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Reply with PONG"}]}]}')
if echo "${RES_3}" | grep -q "InvalidAPICallAsNoApiProductMatchFound"; then
  echo "    [PASS] Unapproved model gemini-1.5-flash rejected (InvalidAPICallAsNoApiProductMatchFound)."
else
  echo "    [FAIL] Expected InvalidAPICallAsNoApiProductMatchFound, got: ${RES_3}"
  exit 1
fi

echo ""
echo "==> Test 4: Approved Model SSE Streaming (gemini-3.8-flash + X-Cost-Center: ${COST_CENTER})"
RES_4=$(curl -s -X POST \
  "${GATEWAY_URL}/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "X-Cost-Center: ${COST_CENTER}" \
  -H "Content-Type: application/json" \
  -d '{
    "contents":[{"role":"user","parts":[{"text":"Reply with PONG"}]}],
    "generationConfig":{"thinkingConfig":{"includeThoughts":true,"thinkingBudget":0}}
  }')
if echo "${RES_4}" | grep -q "PONG"; then
  echo "    [PASS] Received streamed SSE response containing PONG."
else
  echo "    [FAIL] Expected PONG in SSE response, got: ${RES_4}"
  exit 1
fi

echo ""
echo "=============================================================================="
echo "ALL 4 ENTERPRISE GATEWAY TESTS PASSED!"
echo "=============================================================================="
