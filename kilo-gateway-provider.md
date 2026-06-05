# Kilo Gateway LLM Provider - cURL Interaction Guide

## Overview

Kilo AI Gateway is a unified, OpenAI-compatible API that provides access to hundreds of AI models from multiple providers through a single endpoint. It supports usage tracking, cost management, and organization-level controls.

## Base URL

```
https://api.kilo.ai/api/gateway
```

## Authentication

### API Key Setup

Set your Kilo API key as an environment variable:

```bash
export KILO_API_KEY="your_api_key_here"
```

Or in `.env` file:
```
KILO_API_KEY=your_api_key_here
```

### Authorization Header

All authenticated requests require the `Authorization` header:

```bash
-H "Authorization: Bearer $KILO_API_KEY"
```

### Optional Headers

| Header | Description |
|--------|-------------|
| `X-KiloCode-OrganizationId` | Organization context for org-scoped requests |
| `X-KiloCode-TaskId` | Task identifier for prompt cache keying |
| `X-KiloCode-Version` | Client version string |
| `x-kilocode-mode` | Mode hint for kilo-auto model routing |

---

## API Endpoints

### 1. Chat Completions

Primary endpoint for interacting with AI models.

**Endpoint:** `POST /chat/completions`

```bash
curl -X POST "https://api.kilo.ai/api/gateway/chat/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4.5",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is quantum computing?"}
    ],
    "max_tokens": 500,
    "temperature": 0.7
  }'
```

#### Non-streaming Chat Completion

```bash
curl -X POST "https://api.kilo.ai/api/gateway/chat/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4.5",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

#### Streaming Chat Completion

```bash
curl -N -X POST "https://api.kilo.ai/api/gateway/chat/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4.5",
    "messages": [
      {"role": "user", "content": "Write a short story about AI."}
    ],
    "stream": true
  }'
```

### 2. List Models

Retrieve all available models (no authentication required).

**Endpoint:** `GET /models`

```bash
curl -X GET "https://api.kilo.ai/api/gateway/models" \
  -H "Content-Type: application/json"
```

**Response Example:**
```json
{
  "models": [
    {
      "id": "anthropic/claude-opus-4.6",
      "provider": "Anthropic",
      "pricing": {
        "input_token": 0.15,
        "output_token": 0.75
      },
      "context_window": 200000,
      "features": ["chat", "tool_code", "json_mode"]
    }
  ]
}
```

### 3. List Providers

Retrieve all available inference providers (no authentication required).

**Endpoint:** `GET /providers`

```bash
curl -X GET "https://api.kilo.ai/api/gateway/providers" \
  -H "Content-Type: application/json"
```

**Response Example:**
```json
{
  "providers": ["amazon_bedrock", "minimax", "mistral", "moonshot"]
}
```

### 4. Models by Provider

Retrieve models grouped by their provider (no authentication required).

**Endpoint:** `GET /models-by-provider`

```bash
curl -X GET "https://api.kilo.ai/api/gateway/models-by-provider" \
  -H "Content-Type: application/json"
```

**Response Example:**
```json
{
  "grouped_models": {
    "amazon_bedrock": ["claude-3-opus", "claude-3-sonnet"],
    "mistral": ["mistral-large", "mistral-medium"]
  }
}
```

### 5. Fill-in-the-Middle (FIM) Completion

For code completion tasks using Mistral Codestral models.

**Endpoint:** `POST /api/fim/completions`

```bash
curl -X POST "https://api.kilo.ai/api/fim/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistralai/codestral-2508",
    "prompt": "def fibonacci(n):\n    if n <= 1:\n        return n\n    ",
    "suffix": "\n\nprint(fibonacci(10))",
    "max_tokens": 200,
    "stream": false
  }'
```

---

## Request Parameters

### Chat Completions Request Body

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | Model ID (e.g., "anthropic/claude-sonnet-4.5") |
| `messages` | array | Yes | Array of conversation messages |
| `stream` | boolean | No | Enable SSE streaming (default: false) |
| `max_tokens` | number | No | Maximum tokens to generate |
| `temperature` | number | No | Sampling temperature (0-2) |
| `top_p` | number | No | Nucleus sampling (0-1) |
| `stop` | string \| string[] | No | Stop sequences |
| `frequency_penalty` | number | No | Frequency penalty (-2 to 2) |
| `presence_penalty` | number | No | Presence penalty (-2 to 2) |
| `tools` | array | No | Available tools/functions |
| `tool_choice` | ToolChoice | No | Tool selection strategy |
| `response_format` | object | No | For structured output |
| `user` | string | No | End-user identifier for safety |
| `seed` | number | No | Deterministic sampling seed |

### Message Types

```json
[
  {"role": "system", "content": "You are a helpful assistant."},
  {"role": "user", "content": "Hello!"},
  {"role": "user", "content": [
    {"type": "text", "text": "What is in this image?"},
    {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
  ]},
  {"role": "assistant", "content": "I can help with that."},
  {"role": "tool", "content": "{\"temperature\": 72}", "tool_call_id": "call_abc123"}
]
```

---

## Tool Calling

The gateway supports function/tool calling with automatic repair for common issues.

### Tool Calling Request

```bash
curl -X POST "https://api.kilo.ai/api/gateway/chat/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4.5",
    "messages": [{"role": "user", "content": "What is the weather in San Francisco?"}],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get the current weather for a location",
          "parameters": {
            "type": "object",
            "properties": {
              "location": {
                "type": "string",
                "description": "City name"
              }
            },
            "required": ["location"]
          }
        }
      }
    ],
    "tool_choice": "auto"
  }'
```

### Tool Choice Strategies

- `"none"` - Do not call any tool
- `"auto"` - Let the model decide whether to call a tool
- `"required"` - Force the model to call a tool
- `{"type": "function", "function": {"name": "function_name"}}` - Force a specific function

### Tool Call Response

```json
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_abc123",
            "type": "function",
            "function": {
              "name": "get_weather",
              "arguments": "{\"location\":\"San Francisco\"}"
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ]
}
```

---

## Response Format

### Non-streaming Response

```json
{
  "id": "gen-abc123",
  "object": "chat.completion",
  "created": 1739000000,
  "model": "anthropic/claude-sonnet-4.5",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Quantum computing is a type of computation that uses quantum mechanics..."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 150,
    "total_tokens": 175
  }
}
```

### Streaming Response (SSE)

Events are sent as Server-Sent Events:

```
data: {"id":"gen-abc123","object":"chat.completion.chunk","created":1739000000,"model":"anthropic/claude-sonnet-4.5","choices":[{"index":0,"delta":{"role":"assistant","content":"Quan"},"finish_reason":null}]}

data: {"id":"gen-abc123","object":"chat.completion.chunk","created":1739000000,"model":"anthropic/claude-sonnet-4.5","choices":[{"index":0,"delta":{"content":"tum"},"finish_reason":null}]}
```

---

## Common Model Providers and Models

Based on Kilo Gateway support, common provider prefixes include:

- **Anthropic:** `anthropic/claude-opus-4.6`, `anthropic/claude-sonnet-4.5`
- **Mistral:** `mistralai/codestral-2508`, `mistralai/mistral-large`
- **Amazon Bedrock:** `amazon_bedrock/claude-3-opus`
- **OpenAI models** (via various providers)

---

## Quick Reference Cheat Sheet

```bash
# Set API key
export KILO_API_KEY="your_key_here"

# List all models
curl https://api.kilo.ai/api/gateway/models

# List providers
curl https://api.kilo.ai/api/gateway/providers

# Non-streaming chat
curl -X POST "https://api.kilo.ai/api/gateway/chat/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "anthropic/claude-sonnet-4.5", "messages": [{"role": "user", "content": "Hello!"}]}'

# Streaming chat
curl -N -X POST "https://api.kilo.ai/api/gateway/chat/completions" \
  -H "Authorization: Bearer $KILO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "anthropic/claude-sonnet-4.5", "messages": [{"role": "user", "content": "Write a story"}], "stream": true}'
```

---

## Integration with AI Coding Assistants

To use Kilo Gateway with your AI coding assistant:

1. **Set the base URL:** `https://api.kilo.ai/api/gateway`
2. **Use your KILO_API_KEY** as the API key
3. **Select a model** from the available providers (e.g., `anthropic/claude-sonnet-4.5`)
4. **Use OpenAI-compatible SDK** - most SDKs work by changing the base URL and API key

---

## Error Handling

Standard HTTP status codes apply:
- `200` - Success
- `400` - Bad request (invalid parameters)
- `401` - Unauthorized (invalid or missing API key)
- `429` - Rate limit exceeded
- `500` - Server error

**Error Response Example:**
```json
{
  "error": {
    "message": "Invalid API key",
    "type": "authentication_error",
    "code": 401
  }
}
```

---

## Sources

- [Kilo AI Gateway API Reference](https://kilo.ai/docs/gateway/api-reference)
- [Kilo AI Gateway Models and Providers](https://kilo.ai/docs/gateway/models-and-providers)
- [Kilo AI Gateway SDKs and Frameworks](https://kilo.ai/docs/gateway/sdks-and-frameworks)
- [Kilo AI Gateway Quickstart](https://kilo.ai/docs/gateway/quickstart)