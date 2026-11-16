# Apigee Enterprise AI Gateway for Antigravity

This repository contains a sample template to serve as a reference implementation for deploying Apigee as a secure AI gateway for Google Antigravity.

* Designed as a starting point to show how to govern, secure, and route Antigravity traffic.
* Configured entirely using OOTB Apigee policies with zero custom scripting.
* Demonstrates how to satisfy Google Enterprise Gateway guidelines by preserving mandatory client attribution headers and utilizing centralized service account authentication (https://docs.cloud.google.com/gemini/enterprise/docs/ai-developer-tools/deploy-enterprise-gateway)

---

## Architecture Overview

![Apigee X Enterprise AI Gateway Architecture](./architecture.png?v=4)

---

## Employee Identity, Unique API Keys & Governance Model

In this architecture, **every employee using Antigravity (`agy` CLI or IDE) is registered as a Developer in Apigee**:

1. **1 Employee = 1 Apigee Developer + 1 Unique API Key**:
   Each employee receives their own dedicated Apigee Developer App and **unique Consumer API Key**. Administrators can track usage, audit requests, or revoke an individual employee's key at any time without impacting other developers.
2. **Employee Email & Cost Center Bound to the API Key**:
   Both the employee's email ID (`developer.email`) and their `x-cost-center` custom attribute (for example, `CC-1042-Payments-Core` or `CC-2085-AI-Research` in [`developers.json`](./developers.json)) are stored directly on the Developer profile in Apigee and mapped to the employee's API key at runtime by `VerifyAPIKey`:
   - **Per-Employee Token Quotas**: `LLMTokenQuota` uses `verifyapikey.VA-VerifyAPIKey.developer.email` as its quota identifier, enforcing an independent token budget per `(employee, model)`.
   - **Employee-Specific Model Access & Limits**: Because each employee's API key is bound to one or more Apigee API Products, admins can assign different model allowlists or higher/lower daily token budgets to specific employees or roles (e.g., standard engineering vs. AI research).
   - **Tamper-Proof Cost Attribution with Header Fallback**: [`AM-ResolveDeveloperMetadata.xml`](./apiproxy/policies/AM-ResolveDeveloperMetadata.xml) resolves `cost_center` from the employee's Apigee Developer custom attribute (`x-cost-center`) and pushes it to Apigee Analytics (`dc_cost_center`). If the custom attribute is not set on a Developer profile, the gateway falls back to the client's `X-Cost-Center` request header.
3. **Automated Employee Key Self-Service**:
   Onboarding can be fully automated when an employee requests an Antigravity key (for example, through an internal developer portal, IT/ServiceNow workflow, or a GitOps pull request to [`developers.json`](./developers.json)) by running [`./provision-developers.sh`](./provision-developers.sh) or calling the Apigee Management API directly.

---

## How This Satisfies All Enterprise Gateway Requirements

| Enterprise Gateway Requirement | How Apigee X (`agy-gateway`) Implements It |
| :--- | :--- |
| **1. Preserve Client Attribution Headers**<br>(`User-Agent`, `X-Goog-Api-Client`, `X-Cost-Center`) | Apigee preserves client attribution headers verbatim by default, while `<GoogleAccessToken>` on the TargetEndpoint automatically replaces the client's `Authorization` header with a Google Cloud IAM OAuth token. |
| **2. SSE Streaming & Thinking Level Support**<br>(`:streamGenerateContent?alt=sse`) | Forwards SSE streams (`text/event-stream`) and `thinkingConfig` (`thinkingLevel`: `LOW`, `MEDIUM`, `HIGH`) directly to Gemini Platform (`gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-4-argon`), extracting SSE token usage via `<EventFlow content-type="text/event-stream">` and `response.event.current.data`. |
| **3. Acknowledge IDE Telemetry Endpoints**<br>(`POST /v1beta:*` $\rightarrow$ `HTTP 200 OK` `{}`) | Handled via a loopback `<RouteRule>` and `AssignMessage` policy so Antigravity IDE telemetry pings (`POST /v1beta:recordTelemetry`) return `200 OK` `{}` without hitting upstream endpoints. |
| **4. Bearer API Key Auth**<br>(`Authorization: Bearer <KEY>`) | Extracts the employee's unique API key from `Authorization: Bearer <KEY>` and validates it via **VerifyAPIKey** against the authorized Apigee API Product (`api-product.json`). |
| **5. Model Allowlisting & Per-Employee Token Quotas** | Enforces strict model allowlisting and daily token budgets per `(developer.email, model)` combination using Apigee's **LLM Token Quota** policy and [`api-product.json`](./api-product.json). |
| **6. FinOps Chargeback Analytics** | Resolves `cost_center` from the Developer (employee) custom attribute `x-cost-center` (falling back to the `X-Cost-Center` request header if absent) and captures `dc_ax_model_used`, `dc_tokens`, and `dc_cost_center` into **Apigee Analytics** via **DataCapture**. |

---

## Quickstart

### 1. Deploy to Apigee X

Set your GCP Project / Apigee Organization, Environment, and Environment Group Hostname, then run [`./deploy.sh`](./deploy.sh):

```bash
export PROJECT_ID="<YOUR_GCP_PROJECT_ID>"
export APIGEE_ENV="<YOUR_APIGEE_ENV>"
export APIGEE_HOST="<YOUR_APIGEE_HOSTNAME>"

./deploy.sh
```

`./deploy.sh` automatically:
1. Creates the `llm-proxy@${PROJECT_ID}.iam.gserviceaccount.com` Service Account and grants `roles/aiplatform.user` (if not already present).
2. Creates the Apigee Analytics Data Collectors (`dc_ax_model_used`, `dc_tokens`, `dc_cost_center`).
3. Packages, imports, and deploys the `agy-gateway` proxy bundle.
4. Configures the API Product (`agy-gateway-product`) from [`api-product.json`](./api-product.json).
5. Calls [`./provision-developers.sh`](./provision-developers.sh) to register the employees in [`developers.json`](./developers.json) (with their `x-cost-center` custom attribute) and prints each employee's unique **Consumer API Key**.

---

### 2. Provision or Onboard Employee Keys (`developers.json`)

Employee records and their `x-cost-center` custom attributes are defined declaratively in [`developers.json`](./developers.json):

```json
{
  "developers": [
    {
      "email": "alex.rivera@example.com",
      "firstName": "Alex",
      "lastName": "Rivera",
      "userName": "alex-rivera",
      "appName": "agy-key-alex-rivera",
      "apiProducts": [
        "agy-gateway-product"
      ],
      "attributes": [
        {
          "name": "x-cost-center",
          "value": "CC-1042-Payments-Core"
        }
      ]
    },
    {
      "email": "saravana.r@example.com",
      "firstName": "saravana",
      "lastName": "R",
      "userName": "saravana-r",
      "appName": "agy-key-saravana-r",
      "apiProducts": [
        "agy-gateway-product"
      ],
      "attributes": [
        {
          "name": "x-cost-center",
          "value": "CC-2085-AI-Research"
        }
      ]
    }
  ]
}
```

Whenever a new employee requests an Antigravity API key (or an employee's cost center / API Product tier changes), update `developers.json` and run [`./provision-developers.sh`](./provision-developers.sh) without needing to redeploy the proxy:

```bash
export PROJECT_ID="<YOUR_GCP_PROJECT_ID>"
./provision-developers.sh
```

This workflow can also be triggered automatically by a CI/CD pipeline (GitOps PR on `developers.json`), an internal self-service portal (Backstage), or an IT ticketing webhook (ServiceNow / Jira) when an employee requests access to Antigravity.

---

### 3. Verify the Gateway (`./test-gateway.sh`)

Run the automated test suite using one of the provisioned employee Consumer API Keys to verify authentication, telemetry acknowledgment, model allowlisting, and SSE streaming:

```bash
export AGY_LLM_GATEWAY_URL="https://${APIGEE_HOST}/agy-gateway"
export AGY_LLM_GATEWAY_API_KEY="<EMPLOYEE_APIGEE_CONSUMER_KEY>"

./test-gateway.sh
```

---

### 4. Configure Antigravity Clients

You can connect Antigravity (`agy` CLI and IDE) using either **Environment Variables** or an **MDM `admin_settings.json` file**:

#### Option A: Environment Variables (Quick CLI Testing)

```bash
export AGY_LLM_GATEWAY_URL="https://<YOUR_APIGEE_HOSTNAME>/agy-gateway"
export AGY_LLM_GATEWAY_API_KEY="<EMPLOYEE_APIGEE_CONSUMER_KEY>"
export AGY_LLM_GATEWAY_MODELS="gemini-3.8-flash,gemini-3.7-flash,gemini-4-argon"

agy models
agy -p "Reply with PONG"
```

#### Option B: MDM `admin_settings.json` (Enterprise Rollout)

Copy [`admin_settings.example.json`](./admin_settings.example.json) to your OS-level Antigravity MDM path (with `chmod 644` on macOS/Linux):
- **macOS**: `/Library/Application Support/Antigravity/admin_settings.json`
- **Linux**: `/etc/antigravity/admin_settings.json`
- **Windows**: `C:\ProgramData\Antigravity\admin_settings.json`

```json
{
  "gateway": {
    "enabled": true,
    "url": "https://<YOUR_APIGEE_HOSTNAME>/agy-gateway",
    "apiKey": "<EMPLOYEE_APIGEE_CONSUMER_KEY>",
    "wireProtocol": "genai",
    "customHeaders": {
      "X-Cost-Center": "CC-1042-Payments-Core"
    }
  },
  "models": {
    "defaultModelId": "gemini-4-argon",
    "list": [
      { "modelId": "gemini-3.8-flash" },
      { "modelId": "gemini-3.7-flash" },
      { "modelId": "gemini-4-argon" }
    ]
  }
}
```

---

## Managing Allowed Models, Employee Access & Token Quotas

All model access control and token quota limits are externalized in [`api-product.json`](./api-product.json) under `llmOperationGroup.operationConfigs` and mapped to individual employees via [`developers.json`](./developers.json).

### 1. Pre-Configured Allowed Models (`api-product.json`)
By default, [`api-product.json`](./api-product.json) and [`admin_settings.example.json`](./admin_settings.example.json) include the following Gemini models for Antigravity Enterprise:

| Model Name | CLI / API Model ID (`modelId`) | Default Per-Employee Quota (`api-product.json`) |
| :--- | :--- | :--- |
| **Gemini 3.8 Flash** | `gemini-3.8-flash` | `1,000,000` tokens / day |
| **Gemini 3.7 Flash** | `gemini-3.7-flash` | `1,000,000` tokens / day |
| **Gemini 4 Argon** | `gemini-4-argon` | `1,000,000` tokens / day |

### 2. How to Add, Remove, or Tier Allowed Models per Employee
Each entry in `llmOperationGroup.operationConfigs` authorizes a specific Gemini model ID and defines its token quota:
```json
{
  "apiSource": "agy-gateway",
  "llmOperations": [
    {
      "resource": "/**",
      "methods": ["POST"],
      "model": "gemini-4-argon"
    }
  ],
  "llmTokenQuota": {
    "limit": "1000000",
    "interval": "1",
    "timeUnit": "day"
  }
}
```
- **Allowing or Blocking a Model**: Any model **not** listed in the employee's authorized API Product (for example, `gemini-1.5-flash`) is automatically rejected at the gateway by **VerifyAPIKey** with `InvalidAPICallAsNoApiProductMatchFound`.
- **Employee-Specific Tiers**: Because each employee has a dedicated Developer App in [`developers.json`](./developers.json), you can create multiple API Products (e.g., `agy-standard-product` vs. `agy-poweruser-product`) and assign them per employee under `"apiProducts"` to grant custom token limits or model access.

### 3. How Cost-Center Resolution & Per-Employee Token Quotas Work at Runtime
1. **Per-Employee Quota Enforcement (`developer.email`)**:
   - When **VerifyAPIKey** (`VA-VerifyAPIKey`) validates the employee's unique API key, Apigee populates `verifyapikey.VA-VerifyAPIKey.developer.email`.
   - The **LLM Token Quota** policies (`LQ-LLMTokenQuota-Enforce`, `LQ-LLMTokenQuota-Count`, and `LQ-LLMTokenQuota-Count-SSE`) use `<Identifier ref="verifyapikey.VA-VerifyAPIKey.developer.email"/>`, giving each employee an isolated daily token counter per model.
2. **Developer Custom Attribute `x-cost-center` with Header Fallback**:
   - [`AM-ResolveDeveloperMetadata.xml`](./apiproxy/policies/AM-ResolveDeveloperMetadata.xml) checks `verifyapikey.VA-VerifyAPIKey.developer.x-cost-center` (configured in [`developers.json`](./developers.json), such as `CC-1042-Payments-Core`).
   - If present on the Developer profile, Apigee uses that authoritative cost center; if absent, Apigee falls back to the `X-Cost-Center` request header extracted by [`EV-ExtractRequestMetadata.xml`](./apiproxy/policies/EV-ExtractRequestMetadata.xml).
   - [`DC-CaptureGatewayAnalytics.xml`](./apiproxy/policies/DC-CaptureGatewayAnalytics.xml) records `dc_cost_center`, `dc_ax_model_used`, and `dc_tokens` into Apigee Analytics (alongside Apigee's built-in `developer_email` dimension).
