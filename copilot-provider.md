# GitHub Copilot LLM Provider API Interaction Guide

This document describes how to interact with the GitHub Copilot LLM provider using cURL, including authentication, token exchange, and chat completions. It covers the reverse-engineered API endpoints based on the baish project's implementation and the official Copilot SDK patterns.

## Overview

GitHub Copilot provides LLM access through a multi-step authentication and token exchange process:

```
GitHub OAuth (Device Flow) → GitHub Token → Copilot Runtime Token → LLM API
```

## Authentication: OAuth Device Flow

### Step 1: Request Device Code

Request a device code from GitHub to initiate the OAuth device flow.

**Endpoint:**
```
POST https://github.com/login/device/code
```

**Headers:**
```http
Accept: application/json
Content-Type: application/x-www-form-urlencoded
User-Agent: GitHubCopilotChat/0.35.0
```

**cURL Example:**
```bash
# Request device code
curl -sS -X POST https://github.com/login/device/code \
  -H "Accept: application/json" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -d "client_id=Iv1.b507a08c87ecfe98&scope=read:user"
```

**Response:**
```json
{
  "device_code": "32c1e42a7a2b1a5b5b5b5b5b5b5b5b5b5b5b5b5b",
  "user_code": "A1B2-C3D4",
  "verification_uri": "https://github.com/login/device",
  "verification_uri_complete": "https://github.com/login/device?user_code=A1B2-C3D4",
  "expires_in": 900,
  "interval": 5
}
```

### Step 2: Poll for Access Token

Poll the access token endpoint until the user authorizes the application.

**Endpoint:**
```
POST https://github.com/login/oauth/access_token
```

**Headers:**
```http
Accept: application/json
Content-Type: application/x-www-form-urlencoded
User-Agent: GitHubCopilotChat/0.35.0
```

**cURL Example:**
```bash
# Poll for access token (repeat with appropriate interval)
DEVICE_CODE="32c1e42a7a2b1a5b5b5b5b5b5b5b5b5b5b5b5b5b"

curl -sS -X POST https://github.com/login/oauth/access_token \
  -H "Accept: application/json" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -d "client_id=Iv1.b507a08c87ecfe98&device_code=${DEVICE_CODE}&grant_type=urn:ietf:params:oauth:grant-type:device_code"
```

**Success Response:**
```json
{
  "access_token": "gho_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "token_type": "bearer",
  "scope": "read:user"
}
```

**Error Responses:**
```json
// Authorization pending - continue polling
{"error": "authorization_pending"}

// Slow down - increase polling interval
{"error": "slow_down", "interval": 10}

// Access denied
{"error": "access_denied"}
```

### Step 3: Fetch GitHub User Info (Optional)

Verify the authenticated user and get their login.

**Endpoint:**
```
GET https://api.github.com/user
```

**Headers:**
```http
Accept: application/json
Authorization: Bearer gho_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
User-Agent: GitHubCopilotChat/0.35.0
```

**cURL Example:**
```bash
GITHUB_TOKEN="gho_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

curl -sS -X GET https://api.github.com/user \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0"
```

**Response:**
```json
{
  "login": "username"
}
```

## Token Exchange: GitHub Token → Copilot Runtime Token

Exchange the GitHub OAuth token for a Copilot runtime token.

### Endpoint

```
GET https://api.github.com/copilot_internal/v2/token
```

**Headers:**
```http
Accept: application/json
Authorization: Bearer gho_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
User-Agent: GitHubCopilotChat/0.35.0
Editor-Version: vscode/1.107.0
Editor-Plugin-Version: copilot-chat/0.35.0
Copilot-Integration-Id: vscode-chat
```

**cURL Example:**
```bash
GITHUB_TOKEN="gho_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

curl -sS -X GET https://api.github.com/copilot_internal/v2/token \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -H "Editor-Version: vscode/1.107.0" \
  -H "Editor-Plugin-Version: copilot-chat/0.35.0" \
  -H "Copilot-Integration-Id: vscode-chat"
```

**Success Response:**
```json
{
  "token": "ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "expires_at": "2024-01-15T12:00:00Z",
  "refresh_in": 3600,
  "sku": "copilot-chat",
  "user": "username"
}
```

### Determine API Base URL

The Copilot runtime token contains a proxy endpoint hint. Use it to determine the correct API base.

**Extract proxy host from token:**
```bash
COPILOT_TOKEN="ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# If token contains proxy-ep=, extract it
PROXY_HOST=$(echo "$COPILOT_TOKEN" | sed -n 's/.*proxy-ep=\([^;]*\).*/\1/p')

if [ -n "$PROXY_HOST" ]; then
    API_BASE="https://api.${PROXY_HOST#proxy.}"
else
    API_BASE="https://api.individual.githubcopilot.com"
fi
```

## Copilot Runtime API

### List Available Models

**Endpoint:**
```
GET https://api.individual.githubcopilot.com/models
```

**Headers:**
```http
Accept: application/json
Content-Type: application/json
Authorization: Bearer ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
User-Agent: GitHubCopilotChat/0.35.0
Editor-Version: vscode/1.107.0
Editor-Plugin-Version: copilot-chat/0.35.0
Copilot-Integration-Id: vscode-chat
```

**cURL Example:**
```bash
COPILOT_TOKEN="ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
API_BASE="https://api.individual.githubcopilot.com"

curl -sS -X GET "${API_BASE}/models" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${COPILOT_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -H "Editor-Version: vscode/1.107.0" \
  -H "Editor-Plugin-Version: copilot-chat/0.35.0" \
  -H "Copilot-Integration-Id: vscode-chat"
```

**Response:**
```json
[
  {
    "id": "gpt-4",
    "name": "GPT-4",
    "model_picker_enabled": true
  },
  {
    "id": "gpt-4-turbo",
    "name": "GPT-4 Turbo",
    "model_picker_enabled": true
  },
  {
    "id": "claude-3.5-sonnet",
    "name": "Claude 3.5 Sonnet",
    "model_picker_enabled": true
  }
]
```

### Enable Model Policy (Optional)

Some models require explicit policy enablement before use.

**Endpoint:**
```
POST https://api.individual.githubcopilot.com/models/{model}/policy
```

**Headers:**
```http
openai-intent: chat-policy
x-interaction-type: chat-policy
Accept: application/json
Content-Type: application/json
Authorization: Bearer ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
User-Agent: GitHubCopilotChat/0.35.0
Editor-Version: vscode/1.107.0
Editor-Plugin-Version: copilot-chat/0.35.0
Copilot-Integration-Id: vscode-chat
```

**cURL Example:**
```bash
MODEL="gpt-4"
curl -sS -X POST "${API_BASE}/models/${MODEL}/policy" \
  -H "openai-intent: chat-policy" \
  -H "x-interaction-type: chat-policy" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${COPILOT_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -H "Editor-Version: vscode/1.107.0" \
  -H "Editor-Plugin-Version: copilot-chat/0.35.0" \
  -H "Copilot-Integration-Id: vscode-chat" \
  -d '{"state":"enabled"}'
```

## Chat Completions

### OpenAI-Compatible Chat (Chat Completions)

**Endpoint:**
```
POST https://api.individual.githubcopilot.com/chat/completions
```

**Headers:**
```http
Accept: application/json
Content-Type: application/json
Authorization: Bearer ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
User-Agent: GitHubCopilotChat/0.35.0
Editor-Version: vscode/1.107.0
Editor-Plugin-Version: copilot-chat/0.35.0
Copilot-Integration-Id: vscode-chat
X-Initiator: user
Openai-Intent: conversation-edits
```

**cURL Example:**
```bash
COPILOT_TOKEN="ghc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

curl -sS -X POST "${API_BASE}/chat/completions" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${COPILOT_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -H "Editor-Version: vscode/1.107.0" \
  -H "Editor-Plugin-Version: copilot-chat/0.35.0" \
  -H "Copilot-Integration-Id: vscode-chat" \
  -H "X-Initiator: user" \
  -H "Openai-Intent: conversation-edits" \
  -d '{
    "model": "gpt-4",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello, world!"}
    ],
    "stream": false
  }'
```

### Responses API (GPT-5 and newer models)

For models like GPT-5, use the Responses API endpoint.

**Endpoint:**
```
POST https://api.individual.githubcopilot.com/responses
```

**cURL Example:**
```bash
curl -sS -X POST "${API_BASE}/responses" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${COPILOT_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -H "Editor-Version: vscode/1.107.0" \
  -H "Editor-Plugin-Version: copilot-chat/0.35.0" \
  -H "Copilot-Integration-Id: vscode-chat" \
  -d '{
    "model": "gpt-5",
    "input": [
      {"role": "system", "content": [{"type": "input_text", "text": "You are a helpful assistant."}]},
      {"role": "user", "content": [{"type": "input_text", "text": "Hello, world!"}]}
    ]
  }'
```

### Anthropic-Compatible Chat (Claude models)

For Claude models, use the Anthropic-compatible endpoint.

**Endpoint:**
```
POST https://api.individual.githubcopilot.com/v1/messages
```

**cURL Example:**
```bash
curl -sS -X POST "${API_BASE}/v1/messages" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${COPILOT_TOKEN}" \
  -H "User-Agent: GitHubCopilotChat/0.35.0" \
  -H "Editor-Version: vscode/1.107.0" \
  -H "Editor-Plugin-Version: copilot-chat/0.35.0" \
  -H "Copilot-Integration-Id: vscode-chat" \
  -d '{
    "model": "claude-3.5-sonnet",
    "max_tokens": 4096,
    "messages": [
      {"role": "user", "content": [{"type": "text", "text": "Hello, world!"}]}
    ]
  }'
```

## Token Refresh

### Check Token Expiry

Tokens should be refreshed before expiry. The recommended approach is to check if the token expires within the next 60 seconds and refresh if needed.

```bash
# Check if token needs refresh (pseudo-code)
EXPIRY=$(date -d "$TOKEN_EXPIRES_AT" +%s)
NOW=$(date +%s)

if [ $((EXPIRY - NOW)) -le 60 ]; then
    # Token needs refresh - repeat token exchange
    refreshed_json="$(curl -sS -X GET https://api.github.com/copilot_internal/v2/token ...)"
fi
```

### Refresh a Token

To refresh an existing token, repeat the token exchange step with the GitHub token. Tokens are short-lived (typically 1 hour) and should be refreshed proactively.

**Important:** The GitHub token (`gho_*`) is long-lived, while the Copilot token (`ghc_*`) is short-lived. Only the Copilot token needs frequent refreshing.

## Model Family Detection

Different models use different API endpoints:

| Model Prefix | API Family | Endpoint |
|--------------|------------|----------|
| `claude-*` | Anthropic | `/v1/messages` |
| `gpt-5*` | Responses | `/responses` |
| Other | Chat Completions | `/chat/completions` |

**Detection logic:**
```bash
case "$MODEL" in
    claude-*)
        FAMILY="anthropic"
        ;;
    gpt-5*)
        FAMILY="responses"
        ;;
    *)
        FAMILY="chat_completions"
        ;;
esac
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `COPILOT_GITHUB_TOKEN` | Pre-existing GitHub token (skip OAuth) |
| `BAISH_COPILOT_HOST` | Custom GitHub host (GHES/GitHub Enterprise) |
| `COPILOT_GH_HOST` | Alternative host configuration |
| `GH_HOST` | Fallback host configuration |

## GitHub Enterprise / GHES Support

For GitHub Enterprise Server or GitHub Enterprise Cloud, the API base differs:

```bash
# For GHES, the API base follows this pattern
API_BASE="https://copilot-api.${AUTHORITY}"

# For GitHub Enterprise Cloud with custom host
API_BASE="https://copilot-api.{host-without-api-prefix}"
```

## Complete Workflow Example

```bash
#!/bin/bash
set -o pipefail

# Configuration
GITHUB_HOST="${BAISH_COPILOT_HOST:-${COPILOT_GH_HOST:-${GH_HOST:-github.com}}}"
USER_AGENT="GitHubCopilotChat/0.35.0"
EDITOR_VERSION="vscode/1.107.0"
EDITOR_PLUGIN_VERSION="copilot-chat/0.35.0"
INTEGRATION_ID="vscode-chat"
CLIENT_ID="Iv1.b507a08c87ecfe98"
SCOPE="read:user"

# Step 1: Request device code (if no COPILOT_GITHUB_TOKEN)
if [ -z "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "Requesting device code..."
    DEVICE_JSON=$(curl -sS -X POST "https://${GITHUB_HOST}/login/device/code" \
        -H "Accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "User-Agent: ${USER_AGENT}" \
        -d "client_id=${CLIENT_ID}&scope=${SCOPE}")

    DEVICE_CODE=$(echo "$DEVICE_JSON" | jq -r '.device_code')
    USER_CODE=$(echo "$DEVICE_JSON" | jq -r '.user_code')
    VERIFICATION_URI=$(echo "$DEVICE_JSON" | jq -r '.verification_uri')

    echo "To connect Copilot, visit ${VERIFICATION_URI} and enter code ${USER_CODE}"
    echo "Waiting for authorization..."

    # Step 2: Poll for access token
    while true; do
        TOKEN_JSON=$(curl -sS -X POST "https://${GITHUB_HOST}/login/oauth/access_token" \
            -H "Accept: application/json" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -H "User-Agent: ${USER_AGENT}" \
            -d "client_id=${CLIENT_ID}&device_code=${DEVICE_CODE}&grant_type=urn:ietf:params:oauth:grant-type:device_code")

        if [ -n "$(echo "$TOKEN_JSON" | jq -r '.access_token // empty')" ]; then
            GITHUB_TOKEN=$(echo "$TOKEN_JSON" | jq -r '.access_token')
            break
        fi

        sleep 5
    done
else
    GITHUB_TOKEN="${COPILOT_GITHUB_TOKEN}"
fi

# Step 3: Exchange for Copilot token
echo "Exchanging GitHub token for Copilot token..."
DOTCOM_API="https://api.${GITHUB_HOST}"

COPILOT_JSON=$(curl -sS -X GET "${DOTCOM_API}/copilot_internal/v2/token" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "User-Agent: ${USER_AGENT}" \
    -H "Editor-Version: ${EDITOR_VERSION}" \
    -H "Editor-Plugin-Version: ${EDITOR_PLUGIN_VERSION}" \
    -H "Copilot-Integration-Id: ${INTEGRATION_ID}")

COPILOT_TOKEN=$(echo "$COPILOT_JSON" | jq -r '.token')
API_BASE="https://api.individual.githubcopilot.com"

echo "Copilot authorization completed."

# Step 4: List models
echo "Available models:"
curl -sS -X GET "${API_BASE}/models" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${COPILOT_TOKEN}" \
    -H "User-Agent: ${USER_AGENT}" \
    -H "Editor-Version: ${EDITOR_VERSION}" \
    -H "Editor-Plugin-Version: ${EDITOR_PLUGIN_VERSION}" \
    -H "Copilot-Integration-Id: ${INTEGRATION_ID}" | jq -r '.[].id'

# Step 5: Chat completion
echo "Sending chat request..."
curl -sS -X POST "${API_BASE}/chat/completions" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${COPILOT_TOKEN}" \
    -H "User-Agent: ${USER_AGENT}" \
    -H "Editor-Version: ${EDITOR_VERSION}" \
    -H "Editor-Plugin-Version: ${EDITOR_PLUGIN_VERSION}" \
    -H "Copilot-Integration-Id: ${INTEGRATION_ID}" \
    -H "X-Initiator: user" \
    -H "Openai-Intent: conversation-edits" \
    -d '{"model": "gpt-4", "messages": [{"role": "user", "content": "Hello!"}], "stream": false}'
```

## Headers Reference

### Required Headers for All Copilot API Requests

| Header | Value | Purpose |
|--------|-------|---------|
| `Authorization` | `Bearer <copilot_token>` | Authentication (Copilot runtime token) |
| `User-Agent` | `GitHubCopilotChat/0.35.0` | Client identification |
| `Editor-Version` | `vscode/1.107.0` | Editor version tracking |
| `Editor-Plugin-Version` | `copilot-chat/0.35.0` | Plugin version tracking |
| `Copilot-Integration-Id` | `vscode-chat` | Integration identifier |

### Additional Headers for Chat

| Header | Value | Purpose |
|--------|-------|---------|
| `X-Initiator` | `user` or `agent` | Who initiated the request |
| `Openai-Intent` | `conversation-edits` | Request intent classification |

### Additional Headers for Policy

| Header | Value | Purpose |
|--------|-------|---------|
| `openai-intent` | `chat-policy` | Policy operation indicator |
| `x-interaction-type` | `chat-policy` | Interaction type |

---

## Notes and Caveats

1. **Token Security:** The GitHub token (`gho_*`) and Copilot token (`ghc_*`) should be treated as secrets and never logged or exposed.

2. **Rate Limits:** Copilot has rate limits per account. Monitor your usage through the GitHub Copilot settings.

3. **Model Availability:** Available models depend on your Copilot subscription tier. Some models may be restricted.

4. **API Changes:** These endpoints are reverse-engineered and not officially documented. They may change without notice.

5. **Terms of Service:** Using the Copilot API in this manner should comply with GitHub's Terms of Service and Acceptable Use Policy.

6. **GHES:** For GitHub Enterprise, adjust the API endpoints to match your instance's URL structure.
