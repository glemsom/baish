# Plan: Streaming LLM Responses in BAISH

## Progress: 10/10 steps completed

- [x] Step 1: Extend provider discovery (`lib/providers.sh`)
- [x] Step 2: Add streaming stubs to mock provider (`lib/providers/mock.sh`)
- [x] Step 3: Add streaming NDJSON parser utilities (`lib/agent.sh`)
- [x] Step 4: Implement streaming agent loop (`lib/agent.sh`)
- [x] Step 5: Implement Copilot streaming HTTP (`lib/providers/copilot.sh`)
- [x] Step 6: Implement Kilo streaming (`lib/providers/kilo.sh`)
- [x] Step 7: Expand mock provider scenarios
- [x] Step 8: Write tests
- [x] Step 9: Update documentation
- [x] Step 10: Integration verification

## 1. Problem

BAISH currently uses synchronous (blocking) provider calls. The agent waits for the full LLM response before showing anything to the user. This means the user sees nothing while the LLM is "thinking" — generating reasoning, deciding on tool calls, or composing a response.

Modern AI coding assistants stream the LLM's output in real-time, showing intermediate thinking and building tool calls as tokens arrive. This provides immediate feedback that work is happening and lets users understand the LLM's reasoning process.

## 2. Scope

Add streaming support to the BAISH provider interface, agent loop, and terminal UI. Non-streaming mode remains as a fallback. All three built-in providers (copilot, kilo, mock) get streaming implementations.

### Out of scope
- SSE (Server-Sent Events) parsing at the transport layer — we consume SSE from providers but emit our own NDJSON internally.
- Streaming tool *execution* — tools still execute after the stream completes. Only the LLM response generation is streamed.
- Interrupt/cancel mid-stream — the user can Ctrl-C to kill the process, but we don't add a graceful cancel token.

## 3. Streaming Protocol (BAISH Internal NDJSON)

Providers implement a new streaming action that writes **newline-delimited JSON (NDJSON)** to stdout. Each line is one event:

### Event types

**`delta`** — A chunk of text or thinking content.
```json
{"type":"delta","category":"text","content":"I will"}
{"type":"delta","category":"thinking","content":"Let me check"}
```

**`tool_call_delta`** — Incremental tool call argument being built.
```json
{"type":"tool_call_delta","index":0,"tool_call_id":"call-abc","name":"read","arguments_delta":"{\"path\":\""}
```

**`tool_call`** — A complete tool call that the LLM has committed to. Emitted when the provider has fully assembled a tool call. The agent uses this to know the LLM's plan before the stream ends.
```json
{"type":"tool_call","tool_call_id":"call-abc","name":"read","arguments":{"path":"README.md"}}
```

**`done`** — Stream complete. Carries any final metadata.
```json
{"type":"done","finish_reason":"tool_calls"}
{"type":"done","finish_reason":"stop"}
```

**`error`** — An error occurred during streaming.
```json
{"type":"error","message":"HTTP 500: internal error"}
```

### Category values
| Category | Meaning |
|---|---|
| `text` | Normal assistant prose |
| `thinking` | LLM reasoning/thinking tokens (OpenAI `reasoning_content`, Anthropic `thinking` blocks, etc.) |

### finish_reason values
| Value | Meaning |
|---|---|
| `stop` | LLM finished with text only, no tool calls |
| `tool_calls` | LLM emitted tool calls; agent should execute them |
| `length` | Output hit max tokens |
| `error` | Stream ended abnormally |

## 4. Provider Interface Changes

### New required action: `chat_stream`

Each provider must implement `provider_${provider}_chat_stream "$request_json"`.

**Input:** Same `$request_json` as `chat` action (model, messages, tools, etc.)

**Output:** NDJSON events on stdout. Non-NDJSON lines (curl warnings, etc.) go to stderr.

**Exit code:** 0 on success, non-zero on failure.

### New optional action: `has_streaming`

Each provider may implement `provider_${provider}_has_streaming`.

**Output:** Prints `true` or `false` on stdout.

**Default behavior:** If the function does not exist, streaming is assumed **unavailable** (agent falls back to non-streaming).

### Provider dispatch (no changes to `baish_provider_call`)

The existing dispatch in `lib/slash.sh` already routes `baish_provider_call "$provider" chat_stream "$request_json"` to `provider_${provider}_chat_stream "$request_json"` — no dispatch changes needed.

### Provider discovery validation (new)

In `lib/providers.sh`, `baish_provider_discovery_validate_required_actions` must be extended to include `chat_stream` as a required action. Update the array:
```bash
local -a required_actions=(metadata auth list_models chat chat_stream)
```

## 5. HTTP Streaming Infrastructure

### Problem: `provider_copilot_http_request` is synchronous

The current HTTP functions write the full response body to a temp file, then print it at the end. For streaming, we need to process the body as it arrives.

### Solution: New streaming HTTP helper

Each provider that uses curl gets a streaming HTTP function. The pattern:

```bash
provider_copilot_http_stream() {
  local method="$1"
  local url="$2"
  local headers_json="$3"
  local body="${4-}"
  local -a curl_args=()

  # Build curl args (same as http_request)
  while IFS= read -r header_line; do
    [[ -z "$header_line" ]] && continue
    curl_args+=(-H "$header_line")
  done < <(jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$headers_json")

  curl_args+=(-sS -N -X "$method" -w '%{http_code}')

  # -N disables buffering so tokens arrive immediately
  # stdout goes to the caller (our parser), status code appended at end
  if [[ -n "$body" ]]; then
    curl "${curl_args[@]}" --data-binary @- "$url" <<<"$body" || return 1
  else
    curl "${curl_args[@]}" "$url" || return 1
  fi
}
```

**Key flag:** `-N` (or `--no-buffer`) tells curl to write bytes as they arrive instead of buffering.

**Status code extraction:** `-w '%{http_code}'` appends the HTTP status as the last stdout line. The streaming parser reads all lines, treating the last one as the status code.

### SSE parsing

Providers that use OpenAI-compatible endpoints return Server-Sent Events:
```
data: {"choices":[{"delta":{"content":"Hello"}}]}

data: {"choices":[{"delta":{"content":" world"}}]}

data: {"choices":[],"finish_reason":"stop"}
```

The provider's `chat_stream` function pipes curl output through an SSE parser:

```bash
provider_copilot_chat_stream() {
  local request_json="$1"
  # ... build auth, headers, payload ...
  # payload must set stream: true

  provider_copilot_http_stream 'POST' "$url" "$headers_json" "$payload_json" \
    | _copilot_parse_sse_stream
}
```

The `_copilot_parse_sse_stream` helper reads line-by-line, strips `data: ` prefixes, skips empty lines, and emits NDJSON events.

## 6. Agent Loop Changes

### New function: `baish_agent_run_streaming()`

Located in `lib/agent.sh`. Replaces the synchronous path in `baish_agent_run_user_message`.

**Algorithm:**
```
1. Print "Thinking:" header box (empty, or with a spinner)
2. Initialize accumulators: text_content="", thinking_content="", tool_calls_json="[]"
3. While reading NDJSON events from provider chat_stream:
   a. "delta" + "thinking": append to thinking_content, print to terminal (dim style)
   b. "delta" + "text": append to text_content, print to terminal (normal style)
   c. "tool_call_delta": accumulate arguments per tool_call_id
   d. "tool_call": finalize tool call, add to tool_calls_json
   e. "done": exit loop
   f. "error": print error, return 1
4. Close the "Thinking:" box
5. If thinking_content was emitted, print it as a "Thinking" block
6. If text_content was emitted, print it as a "Reply" block
7. If tool_calls_json is non-empty, execute tools (same as current flow)
8. If finish_reason == "tool_calls", loop back for another round
9. If finish_reason == "stop", return
```

### Terminal output during streaming

While streaming, the agent prints tokens directly to stdout without the box formatting (which requires knowing the full content). The box is printed **before** streaming starts (as a header) and **after** (as a footer). During streaming:

- **Thinking tokens** are printed in dim style on their own lines
- **Text tokens** are printed in bold/white style on their own lines
- No wrapping/box during streaming — just raw tokens with style prefixes
- After streaming completes, the full content is re-rendered in the box for the transcript

**Simpler alternative:** Don't re-render. Print the box header, then stream tokens inside the box, then print the box footer. This is what most terminal agents do.

```
╭─ Thinking
│ I'll look at the files first...
│ dim Let me read agent.sh...
╰─
```

### Modified `baish_agent_run_user_message()`

The existing function should:
1. Check if `provider_${provider}_has_streaming` returns `true`
2. If yes, call `baish_agent_run_streaming`
3. If no, fall back to the current synchronous flow

## 7. Terminal UI Changes

### Current: `baish_agent_print_assistant_response()`
Prints a complete box with the full assistant text. Already modified to accept a label parameter.

### New: `baish_agent_print_streaming_header()` and `baish_agent_print_streaming_footer()`

```bash
baish_agent_print_streaming_header() {
  local label="${1:-Thinking}"
  printf '%s╭─%s %s%s%s\n' \
    "$(baish_agent_style_dim)" \
    "$(baish_agent_style_reset)" \
    "$(baish_agent_style_cyan)" \
    "$label" \
    "$(baish_agent_style_reset)"
}

baish_agent_print_streaming_footer() {
  printf '%s╰─%s\n' \
    "$(baish_agent_style_dim)" \
    "$(baish_agent_style_reset)"
}
```

### Streaming token printer

```bash
baish_agent_print_streaming_token() {
  local category="$1"
  local content="$2"

  case "$category" in
    thinking)
      printf '%s│%s %s%s%s\n' \
        "$(baish_agent_style_dim)" \
        "$(baish_agent_style_reset)" \
        "$(baish_agent_style_dim)" \
        "$content" \
        "$(baish_agent_style_reset)"
      ;;
    text)
      printf '%s│%s %s%s%s\n' \
        "$(baish_agent_style_dim)" \
        "$(baish_agent_style_reset)" \
        "$(baish_agent_style_bold_white)" \
        "$content" \
        "$(baish_agent_style_reset)"
      ;;
  esac
}
```

## 8. Provider Implementation Details

### 8.1 Copilot Provider

#### `provider_copilot_chat_stream()`

1. Get active auth and API base (same as `chat`)
2. Determine model family (same as `chat`)
3. Build streaming payload — set `stream: true` instead of `stream: false`
4. Call `provider_copilot_http_stream` with streaming-enabled curl
5. Pipe output through family-specific SSE parser

**Payload change (chat_completions):**
```json
{
  "model": "...",
  "stream": true,
  "stream_options": {"include_usage": true},
  ...
}
```

**SSE event format (OpenAI chat_completions):**
```json
{"choices":[{"delta":{"content":"Hello"},"index":0}]}
{"choices":[{"delta":{"reasoning_content":"Let me think"},"index":0}]}
{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"read","arguments":"{\"path\"":"}}}}],"index":0}]}
{"choices":[],"finish_reason":"tool_calls"}
```

**SSE event format (Anthropic messages):**
```json
{"type":"message_start","message":{"id":"msg-1","content":[]}}
{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"Let me"}}
{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" check"}}
{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}
{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool-1","name":"read","input":{}}}
{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\""}}
{"type":"message_delta","delta":{"stop_reason":"tool_use"}}
{"type":"message_stop"}
```

**SSE event format (Responses):**
Responses API uses a different streaming format. Copilot may or may not support it. For V1, skip Responses API streaming and fall back to non-streaming for models using that family.

#### `provider_copilot_has_streaming()`

Returns `true` for `chat_completions` and `anthropic` families, `false` for `responses` family (until Responses streaming is implemented).

### 8.2 Kilo Provider

Similar to Copilot but simpler (single endpoint family).

#### `provider_kilo_chat_stream()`

1. Build streaming payload (`stream: true`)
2. Call streaming HTTP
3. Parse SSE → NDJSON

#### `provider_kilo_has_streaming()`

Returns `true` (assuming Kilo supports OpenAI-compatible streaming).

### 8.3 Mock Provider

The mock provider simulates streaming for testing.

#### `provider_mock_chat_stream()`

Reads the same scenarios as `chat`. For each scenario:
1. Emit `delta` events with small text chunks (simulating tokenization)
2. If scenario has tool calls, emit `tool_call_delta` events, then `tool_call` events
3. Emit `done` event

Add a small `sleep 0.05` between events to simulate realistic streaming latency.

#### `provider_mock_has_streaming()`

Returns `true`.

## 9. Backward Compatibility

- The existing `chat` action and `baish_provider_chat_json()` remain unchanged
- The agent loop falls back to non-streaming if:
  - Provider doesn't implement `chat_stream`
  - Provider's `has_streaming` returns `false`
  - Environment variable `BAISH_STREAMING=0` is set
- Add `BAISH_STREAMING` env var: `1` (enable, default), `0` (disable, force synchronous)
- Non-interactive mode (piped stdin) uses non-streaming by default (avoids corrupting output)

## 10. File Change Summary

| File | Changes |
|---|---|
| `lib/providers.sh` | Add `chat_stream` to required actions list |
| `lib/providers/copilot.sh` | Add `provider_copilot_chat_stream`, `provider_copilot_has_streaming`, `provider_copilot_http_stream`, `_copilot_parse_sse_chat`, `_copilot_parse_sse_anthropic` |
| `lib/providers/kilo.sh` | Add `provider_kilo_chat_stream`, `provider_kilo_has_streaming`, `provider_kilo_http_stream`, `_kilo_parse_sse` |
| `lib/providers/mock.sh` | Add `provider_mock_chat_stream`, `provider_mock_has_streaming` |
| `lib/agent.sh` | Add `baish_agent_run_streaming`, `baish_agent_print_streaming_header`, `baish_agent_print_streaming_footer`, `baish_agent_print_streaming_token`. Modify `baish_agent_run_user_message` to choose streaming vs non-streaming |
| `lib/slash.sh` | No changes (dispatch already generic) |
| `docs/adr/0020-streaming-llm-responses.md` | New ADR documenting the design decision |
| `test/streaming.bats` | New test file |
| `README.md` | Update limitations section (remove "No streaming responses") |

## 11. Implementation Steps (Ordered)

### Step 1: Extend provider discovery (lib/providers.sh)
- Add `chat_stream` to `required_actions` array in `baish_provider_discovery_validate_required_actions`

### Step 2: Add streaming stubs to mock provider (lib/providers/mock.sh)
- Implement `provider_mock_has_streaming` → prints `true`
- Implement `provider_mock_chat_stream` with a simple text-delta scenario
- Add small sleep between events to simulate real streaming
- Test with: `BAISH_PROVIDER=mock BAISH_MOCK_SCENARIO=simple_text baish`

### Step 3: Add streaming NDJSON parser utilities (lib/agent.sh)
- Add `baish_agent_parse_streaming_event()` — reads one NDJSON line, sets global vars for event type/category/content/etc.
- Add `baish_agent_print_streaming_header/footer/token`

### Step 4: Implement streaming agent loop (lib/agent.sh)
- Add `baish_agent_run_streaming()` — the main streaming consumer
- Integrate into `baish_agent_run_user_message()` with has_streaming check
- Add `BAISH_STREAMING` env var support

### Step 5: Implement Copilot streaming HTTP (lib/providers/copilot.sh)
- Add `provider_copilot_http_stream()` — streaming curl with `-N`
- Add `provider_copilot_has_streaming()` — returns true/false by model family
- Add SSE parsers: `_copilot_parse_sse_chat`, `_copilot_parse_sse_anthropic`
- Add `provider_copilot_chat_stream()` — orchestrates auth → streaming HTTP → SSE parsing → NDJSON

### Step 6: Implement Kilo streaming (lib/providers/kilo.sh)
- Add `provider_kilo_http_stream()`
- Add `provider_kilo_has_streaming()`
- Add `_kilo_parse_sse`
- Add `provider_kilo_chat_stream()`

### Step 7: Expand mock provider scenarios
- Add tool-call streaming scenarios to match existing `chat` scenarios
- Ensure all mock scenarios work in both `chat` and `chat_stream`

### Step 8: Write tests
- Add `test/streaming.bats`
- Test NDJSON event parsing
- Test mock streaming scenarios
- Test fallback to non-streaming when `BAISH_STREAMING=0`
- Test provider discovery validation requires `chat_stream`

### Step 9: Update documentation
- Create `docs/adr/0020-streaming-llm-responses.md`
- Update `README.md` limitations section

### Step 10: Integration verification
- Manual test with Copilot: verify thinking content appears in real-time
- Manual test with Kilo: verify streaming works
- Verify non-interactive mode falls back to non-streaming
- Verify `BAISH_STREAMING=0` forces non-streaming

## 12. Testing Strategy

### Unit tests (bats)
- `test/streaming.bats`:
  - `provider_mock_chat_stream` emits valid NDJSON
  - Events have correct types and categories
  - `provider_mock_has_streaming` returns `true`
  - Agent correctly accumulates text_content and thinking_content from stream
  - Agent correctly accumulates tool_calls from stream deltas
  - `baish_agent_run_user_message` chooses streaming when available
  - `BAISH_STREAMING=0` forces non-streaming fallback

### Manual testing
- Run `baish` with mock provider and observe streaming output
- Run `baish` with Copilot and observe thinking + text streaming
- Verify the terminal box renders correctly during and after streaming
- Test with models that support thinking (e.g., Claude, o-series)

## 13. Key Design Decisions

### Why NDJSON internally instead of SSE?
SSE is a transport format (data: prefix, double-newline delimiters). NDJSON is simpler for bash to parse (one JSON object per line, no prefix stripping). Providers parse SSE from the HTTP response and re-emit as NDJSON on stdout.

### Why not stream tool execution?
Tool execution is synchronous by design in BAISH (ADR-0001). Streaming tool execution would require a fundamentally different agent loop with concurrent tool execution. This plan keeps tool execution synchronous — only the LLM's response generation is streamed.

### How is "thinking" distinguished from "text"?
- **OpenAI models:** `delta.reasoning_content` or `delta.reasoning` fields
- **Anthropic models:** `content_block_delta` with `type: "thinking_delta"`
- **Copilot proxy:** depends on underlying model family; the provider parser maps each family's thinking field to `category: "thinking"` in NDJSON

### What if a model doesn't support thinking?
The provider simply never emits `category: "thinking"` deltas. The UI shows only text content. No error.

### What if the stream fails mid-way?
The `error` event type handles this. The agent prints the error message and falls back gracefully. The partially accumulated content is discarded (the next round will retry).

### Performance considerations
- Bash `read` loop for NDJSON: ~1ms per event, acceptable for token-by-token streaming
- Each curl response byte is processed individually; the `-N` flag ensures no buffering delay
- Style codes (`\033[2m`, etc.) add minimal overhead
- No `jq` calls inside the hot loop — event parsing uses `read` + string manipulation, with `jq` only for final tool_call assembly
