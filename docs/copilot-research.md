# Copilot research for BAISH V1

Last updated: 2026-05-29

This note records the current Copilot behavior that Phase 7 implementation in BAISH is based on.

## Sources used

1. Live unauthenticated endpoint probes with `curl`
2. Official npm packages:
   - `@github/copilot` `1.0.55`
   - `@vscode/copilot-api` `0.4.3`
3. GitHub OAuth device-flow docs:
   - `https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow`

## Summary

- Copilot auth still starts with GitHub OAuth device flow.
- The current official Copilot CLI package uses:
  - client id: `Ov23ctDVkRmgkPke0Mmm`
  - scope: `read:user,read:org,repo,gist`
- After obtaining a GitHub OAuth token, official clients exchange it at:
  - `GET https://api.github.com/copilot_internal/v2/token`
- Current Copilot API base remains:
  - `https://api.githubcopilot.com`
- Model listing endpoint remains:
  - `GET https://api.githubcopilot.com/models`
- Chat endpoint remains:
  - `POST https://api.githubcopilot.com/chat/completions`
- Official packages treat the chat/model API as OpenAI-compatible enough to use:
  - `messages`
  - `tools`
  - `tool_choice`
  - `parallel_tool_calls`
  - `tool_calls`
  - `stream: false`

## Device code authentication

### Endpoint

Official CLI package (`@github/copilot` `1.0.55`) contains:

- `/login/device/code`
- `/login/oauth/access_token`
- client id `Ov23ctDVkRmgkPke0Mmm`
- scope `read:user,read:org,repo,gist`

### Request shape

Device code request:

```http
POST https://github.com/login/device/code
Content-Type: application/x-www-form-urlencoded
Accept: application/json

client_id=Ov23ctDVkRmgkPke0Mmm&scope=read:user,read:org,repo,gist
```

Polling request:

```http
POST https://github.com/login/oauth/access_token
Content-Type: application/x-www-form-urlencoded
Accept: application/json

client_id=Ov23ctDVkRmgkPke0Mmm&device_code=<device_code>&grant_type=urn:ietf:params:oauth:grant-type:device_code
```

### Response shape

Device code response follows GitHub OAuth device flow docs:

```json
{
  "device_code": "...",
  "user_code": "ABCD-EFGH",
  "verification_uri": "https://github.com/login/device",
  "expires_in": 900,
  "interval": 5
}
```

Polling response is either a token:

```json
{
  "access_token": "gho_...",
  "token_type": "bearer",
  "scope": "read:user,read:org,repo,gist"
}
```

or one of the documented device-flow errors:

- `authorization_pending`
- `slow_down`
- `access_denied`
- `expired_token` / `token_expired`

## GitHub token -> Copilot token exchange

### Endpoint

```http
GET https://api.github.com/copilot_internal/v2/token
Authorization: Bearer <github_oauth_token>
Accept: application/json
```

### Observed unauthenticated failures

Without auth:

```json
{
  "message": "Requires authentication",
  "documentation_url": "https://docs.github.com/rest",
  "status": "401"
}
```

With a fake bearer token:

```json
{
  "message": "Bad credentials",
  "documentation_url": "https://docs.github.com/rest",
  "status": "401"
}
```

### Response shape used by current clients

`@vscode/copilot-api` types expose `endpoints` and `sku` on the Copilot-token payload, and current clients use this response to discover the effective Copilot API domain.

The BAISH implementation assumes the token response includes at least:

```json
{
  "token": "...",
  "expires_at": 4102444800,
  "refresh_in": 900,
  "endpoints": {
    "api": "https://api.githubcopilot.com"
  },
  "sku": "copilot_individual"
}
```

### Confidence

- `endpoints` and `sku`: strong, from official package types
- `token` exchange endpoint: strong, from official package code and live 401 probes
- exact full success payload: moderate; live success response was not available during implementation because no valid Copilot account token was available in this environment

## Required request headers for models/chat

Official `@vscode/copilot-api` adds these headers for model/chat requests:

- `Authorization: Bearer <copilot_token>`
- `X-GitHub-Api-Version: 2026-06-01`
- `VScode-SessionId: <uuid>`
- `VScode-MachineId: <uuid>`
- `Editor-Device-Id: <uuid>`
- `Editor-Plugin-Version: copilot-chat/<version>`
- `Editor-Version: vscode/<version>`
- `Copilot-Integration-Id: code-oss`

BAISH mirrors this header shape conservatively for compatibility.

## Model listing

### Endpoint

```http
GET https://api.githubcopilot.com/models
Authorization: Bearer <copilot_token>
```

### Observed unauthenticated failure

Live probe without auth returned HTTP 400 with plain-text body:

```text
bad request: missing required Authorization header
```

### Response shape

Official `@vscode/copilot-api` types model this as an array of objects with fields including:

```json
{
  "id": "gpt-4o",
  "name": "GPT-4o",
  "model_picker_enabled": true,
  "supported_endpoints": ["/chat/completions"],
  "capabilities": {
    "supports": {
      "tool_calls": true,
      "parallel_tool_calls": true,
      "streaming": true
    }
  }
}
```

Important fields for BAISH:

- `id`
- `name`
- `model_picker_enabled`
- `capabilities.supports.tool_calls`
- `capabilities.supports.parallel_tool_calls`

## Chat completions

### Endpoint

```http
POST https://api.githubcopilot.com/chat/completions
Authorization: Bearer <copilot_token>
Content-Type: application/json
```

### Observed unauthenticated failure

Live probe without auth returned HTTP 400 with plain-text body:

```text
bad request: missing required Authorization header
```

### Request shape

Current official package structure strongly suggests OpenAI-compatible chat-completions requests.

BAISH uses this shape:

```json
{
  "model": "gpt-4o",
  "stream": false,
  "tool_choice": "auto",
  "parallel_tool_calls": true,
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read",
        "description": "Read a file.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {"type": "string"}
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    }
  ],
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "Inspect idea.md"}
  ]
}
```

### Response shape

BAISH normalizes an OpenAI-style response of this form:

```json
{
  "choices": [
    {
      "message": {
        "content": null,
        "tool_calls": [
          {
            "id": "call-1",
            "type": "function",
            "function": {
              "name": "read",
              "arguments": "{\"path\":\"idea.md\"}"
            }
          }
        ]
      }
    }
  ]
}
```

into BAISH's provider-neutral response:

```json
{
  "assistant_text": null,
  "tool_calls": [
    {
      "id": "call-1",
      "name": "read",
      "arguments": {
        "path": "idea.md"
      }
    }
  ]
}
```

## Tool/function calling support

### What is verified

- Official model types include:
  - `tool_calls: true`
  - `parallel_tool_calls: true`
- Official packages target `/chat/completions` and expose OpenAI-style tool-call-related capabilities.
- BAISH request/response normalization matches that shape.

### What is still unverified live

Because no valid Copilot subscription token was available during implementation, I could not complete a live authenticated tool-call round trip against the production endpoint.

So, for V1:

- request shape is strongly inferred from official packages
- live unauthenticated endpoint existence is confirmed
- live authenticated tool-call execution remains a known risk

## Non-streaming support

Official package capabilities include `streaming`, but the chat endpoint remains usable in standard chat-completions mode and BAISH explicitly sends:

```json
{"stream": false}
```

This keeps Phase 7 aligned with the V1 plan: no streaming.

## Error shapes collected so far

### Auth failure

From live probes:

- GitHub token exchange without auth:
  - HTTP 401 JSON `Requires authentication`
- GitHub token exchange with fake auth:
  - HTTP 401 JSON `Bad credentials`
- Copilot models/chat without auth:
  - HTTP 400 plain text `bad request: missing required Authorization header`

### Model failure

- Missing auth on `/models` is confirmed as above.
- Authenticated-but-invalid-model failure shape was not live-tested in this environment.

### Context overflow

- Not live-tested against the real endpoint in this environment.
- BAISH still treats obvious provider errors containing phrases such as `context length`, `context_length_exceeded`, `request too large`, or `prompt too large` as BAISH-level overflow failures.

### Tool-call formatting errors

- Not live-tested against the real endpoint in this environment.
- Expected likely failure mode is an OpenAI-style 4xx validation error, but that remains unconfirmed.

## Implementation choices in BAISH

Phase 7 implementation uses:

- device flow via GitHub OAuth endpoints
- persisted plain JSON auth state in `~/.baish/auth/copilot.json`
- GitHub-token refresh through `/copilot_internal/v2/token`
- dynamic Copilot API base from `endpoints.api` when present
- `/models` for model selection
- `/chat/completions` with OpenAI-style `tools` and `tool_calls`
- non-streaming only

## Remaining risks / follow-up

1. Confirm a full authenticated end-to-end chat + tool-call with a real Copilot account.
2. Record real 4xx/5xx bodies for:
   - invalid model id
   - context overflow
   - malformed tool arguments
3. Confirm whether BAISH can keep its own editor/plugin identifiers long-term, or whether the VS Code-shaped compatibility headers need revision.
4. Confirm the exact successful `/copilot_internal/v2/token` payload fields against a live token exchange and update this document if GitHub changes them.
