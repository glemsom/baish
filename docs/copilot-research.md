# Copilot research for BAISH V1

Last updated: 2026-05-29

This note records the Copilot behavior BAISH now follows, based on the repository research captured in `../COPILOT.md`.

## Summary

BAISH now mirrors the `pi` Copilot flow more closely:

1. GitHub OAuth device flow, or an env-supplied GitHub token input
2. GitHub token exchange at `GET /copilot_internal/v2/token`
3. Runtime Copilot API base derived from the returned Copilot token
4. Model-family routing to one of:
   - `/chat/completions`
   - `/responses`
   - `/v1/messages`

BAISH still keeps one deliberate difference from `pi`: no streaming yet.

## Authentication flow

### Device flow

BAISH uses the same device-flow inputs described in `COPILOT.md`:

- device-code endpoint: `POST https://github.com/login/device/code`
- access-token poll endpoint: `POST https://github.com/login/oauth/access_token`
- client id: `Iv1.b507a08c87ecfe98`
- scope: `read:user`
- user agent: `GitHubCopilotChat/0.35.0`

### Env-token path

When one of these env vars is present, BAISH skips the interactive device prompt:

1. `COPILOT_GITHUB_TOKEN`
2. `GH_TOKEN`
3. `GITHUB_TOKEN`

Important: these env vars are treated as GitHub-token inputs, not as direct runtime Copilot bearer tokens. BAISH still exchanges them at `/copilot_internal/v2/token` before listing models or sending chat requests.

### GitHub token -> Copilot token exchange

BAISH exchanges the GitHub token at:

```http
GET https://api.github.com/copilot_internal/v2/token
Accept: application/json
Authorization: Bearer <github_token>
User-Agent: GitHubCopilotChat/0.35.0
Editor-Version: vscode/1.107.0
Editor-Plugin-Version: copilot-chat/0.35.0
Copilot-Integration-Id: vscode-chat
```

BAISH persists the GitHub token for device-flow auth, but in env-token mode it persists metadata only and does not store either the env secret or the exchanged Copilot bearer token.

## Runtime API base resolution

BAISH no longer assumes `https://api.githubcopilot.com`.

Instead it derives the runtime API base from the exchanged Copilot token by parsing the `proxy-ep=...` field, for example:

```text
tid=...;exp=...;proxy-ep=proxy.individual.githubcopilot.com;...
```

which becomes:

```text
https://api.individual.githubcopilot.com
```

If token parsing fails, BAISH falls back to:

- `https://api.individual.githubcopilot.com` for `github.com`
- `https://copilot-api.<enterprise-host>` for enterprise hosts

## Static Copilot headers

For runtime Copilot requests BAISH now uses the VS Code-shaped headers from the research:

- `Authorization: Bearer <copilot_token>`
- `User-Agent: GitHubCopilotChat/0.35.0`
- `Editor-Version: vscode/1.107.0`
- `Editor-Plugin-Version: copilot-chat/0.35.0`
- `Copilot-Integration-Id: vscode-chat`

## Dynamic Copilot headers

For conversation requests BAISH also sends:

- `X-Initiator: user|agent`
- `Openai-Intent: conversation-edits`

BAISH does not implement image support yet, so it does not currently emit `Copilot-Vision-Request`.

## Model listing

BAISH lists models from the token-derived runtime base:

```http
GET <api_base>/models
Authorization: Bearer <copilot_token>
```

The response is normalized to a model array and filtered by `model_picker_enabled != false`.

## Model policy enablement

Before chat requests BAISH now makes a best-effort enablement call that matches the researched flow:

```http
POST <api_base>/models/{model}/policy
Content-Type: application/json
Authorization: Bearer <copilot_token>
openai-intent: chat-policy
x-interaction-type: chat-policy

{"state":"enabled"}
```

BAISH treats this as best-effort and lets the actual chat request surface any hard model-availability error.

## Endpoint routing by model family

BAISH now routes by model family instead of sending everything to `/chat/completions`.

### Chat completions

These continue to use OpenAI chat-completions shape:

- `gpt-4o`
- `gpt-4.1`
- Gemini families
- Grok Code Fast families
- any other non-`gpt-5*`, non-`claude-*` model ids

Endpoint:

```http
POST <api_base>/chat/completions
```

### Responses API

`gpt-5*` models now use OpenAI Responses-style payloads.

Endpoint:

```http
POST <api_base>/responses
```

BAISH also follows the researched defaults:

- `stream: false`
- `store: false`
- omit `reasoning` unless explicitly requested in future work

### Anthropic Messages API

`claude-*` models now use Anthropic Messages-style payloads.

Endpoint:

```http
POST <api_base>/v1/messages
```

BAISH still uses the Copilot bearer token and Copilot headers for these requests.

## Tool calling

BAISH still uses provider-native tool calling, but now across three request shapes:

- chat-completions `tools` / `tool_calls`
- responses `tools` / `function_call` / `function_call_output`
- anthropic `tools` / `tool_use` / `tool_result`

All three normalize back into BAISH's provider-neutral response shape:

```json
{
  "assistant_text": "... or null",
  "tool_calls": [
    {
      "id": "...",
      "name": "...",
      "arguments": {}
    }
  ]
}
```

## Streaming

`pi` supports streaming, but BAISH still does not. Every BAISH Copilot request is non-streaming for now.

## What changed from the previous BAISH research

The earlier BAISH note assumed the newer official CLI-style flow:

- client id `Ov23ctDVkRmgkPke0Mmm`
- broader OAuth scope
- fixed runtime base `https://api.githubcopilot.com`
- single `/chat/completions` inference path
- direct env-token bearer mode

That is no longer the documented BAISH approach.

BAISH now follows the `pi`-researched flow instead:

- client id `Iv1.b507a08c87ecfe98`
- scope `read:user`
- token-derived runtime base
- `/chat/completions`, `/responses`, and `/v1/messages`
- env tokens still go through the GitHub-to-Copilot token exchange

## Verification status

What is covered in-repo:

- shell-level tests for the auth flow
- shell-level tests for token-derived API base selection
- shell-level tests for env-token exchange behavior
- shell-level tests for routing across all three inference endpoint families
- shell-level tests for provider-native tool-call normalization

What remains unverified live:

- authenticated end-to-end requests against a real Copilot account
- exact live response bodies for malformed requests and unsupported models
- image/vision request handling
- streaming behavior
