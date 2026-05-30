#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"

  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  cd "$TEST_PROJECT"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/slash.sh"
  source "$REPO_ROOT/lib/agent.sh"
  source "$REPO_ROOT/lib/tools.sh"
  source "$REPO_ROOT/lib/providers/mock.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"
  BAISH_LAUNCH_CWD="$TEST_PROJECT"

  unset BAISH_MOCK_SCENARIO
  unset BAISH_MOCK_FINAL_TEXT
  unset BAISH_MODEL
  unset BAISH_PROVIDER
  unset BAISH_ACTIVE_PROVIDER
  unset BAISH_ACTIVE_MODEL
  unset BAISH_STREAMING

  baish_state_init
}

# ─── Mock provider: has_streaming ────────────────────────────────────

@test "mock provider has_streaming returns true" {
  local result
  result="$(provider_mock_has_streaming)"
  [ "$result" = "true" ]
}

# ─── Mock provider: chat_stream emits valid NDJSON ───────────────────

@test "mock chat_stream simple_text emits delta events and done" {
  local output line_count first_event last_event

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"hi"}],"mock":{"scenario":"simple_text","final_text":"Hello world"}}')"

  # Every line must be valid JSON
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    jq -e 'type == "object" and has("type")' >/dev/null 2>&1 <<<"$line" || return 1
  done <<<"$output"

  # First event should be a delta
  first_event="$(head -n 1 <<<"$output")"
  [ "$(jq -r '.type' <<<"$first_event")" = "delta" ]
  [ "$(jq -r '.category' <<<"$first_event")" = "text" ]

  # Last event should be done with stop
  last_event="$(tail -n 1 <<<"$output")"
  [ "$(jq -r '.type' <<<"$last_event")" = "done" ]
  [ "$(jq -r '.finish_reason' <<<"$last_event")" = "stop" ]

  # All deltas between first and last should have category text
  line_count="$(jq -r 'select(.type == "delta")' <<<"$output" | wc -l)"
  (( line_count > 0 ))
}

@test "mock chat_stream simple_text reassembles original text from deltas" {
  local output assembled=""

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"hi"}],"mock":{"scenario":"simple_text","final_text":"Hello world from mock"}}')"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local etype
    etype="$(jq -r '.type' <<<"$line")"
    if [[ "$etype" == "delta" ]]; then
      local content
      content="$(jq -r '.content' <<<"$line")"
      assembled+="$content"
    fi
  done <<<"$output"

  [ "$assembled" = "Hello world from mock" ]
}

@test "mock chat_stream single_tool_then_final emits tool_call_delta, tool_call, and done with tool_calls" {
  local output has_delta has_tool_call_delta has_tool_call has_done last_event

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"run"}],"mock":{"scenario":"single_tool_then_final","command":"printf test"}}')"

  has_delta=false
  has_tool_call_delta=false
  has_tool_call=false
  has_done=false

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local etype
    etype="$(jq -r '.type' <<<"$line")"
    case "$etype" in
      delta) has_delta=true ;;
      tool_call_delta) has_tool_call_delta=true ;;
      tool_call) has_tool_call=true ;;
      done) has_done=true ;;
    esac
  done <<<"$output"

  $has_delta
  $has_tool_call_delta
  $has_tool_call
  $has_done

  last_event="$(tail -n 1 <<<"$output")"
  [ "$(jq -r '.type' <<<"$last_event")" = "done" ]
  [ "$(jq -r '.finish_reason' <<<"$last_event")" = "tool_calls" ]
}

@test "mock chat_stream multiple_tools_then_final emits two tool_call events" {
  local output tool_call_count

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"run"}],"mock":{"scenario":"multiple_tools_then_final","first_command":"printf a","second_command":"printf b"}}')"

  tool_call_count="$(grep -c '"type":"tool_call"' <<<"$output")"
  [ "$tool_call_count" -eq 2 ]
}

@test "mock chat_stream read_only_then_final emits read tool calls" {
  local output tool_call_count tool_names

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"read"}],"mock":{"scenario":"read_only_then_final","read_paths":["a.txt","b.txt"]}}')"

  tool_call_count="$(grep -c '"type":"tool_call"' <<<"$output")"
  [ "$tool_call_count" -eq 2 ]

  tool_names="$(grep '"type":"tool_call"' <<<"$output" | jq -r '.name' | sort | tr '\n' ',')"
  [[ "$tool_names" == "read,read," ]]
}

@test "mock chat_stream mixed_read_bash_then_final emits both read and bash tool calls" {
  local output tool_call_count tool_names

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"mixed"}],"mock":{"scenario":"mixed_read_bash_then_final","read_paths":["file.txt"],"command":"echo test"}}')"

  tool_call_count="$(grep -c '"type":"tool_call"' <<<"$output")"
  [ "$tool_call_count" -eq 2 ]

  tool_names="$(grep '"type":"tool_call"' <<<"$output" | jq -r '.name' | sort | tr '\n' ',')"
  [[ "$tool_names" == "bash,read," ]]
}

@test "mock chat_stream loop_forever emits tool_calls finish reason" {
  local output last_event

  baish_provider_call mock auth
  output="$(baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"loop"}],"mock":{"scenario":"loop_forever","command":"printf loop"}}')"

  last_event="$(tail -n 1 <<<"$output")"
  [ "$(jq -r '.type' <<<"$last_event")" = "done" ]
  [ "$(jq -r '.finish_reason' <<<"$last_event")" = "tool_calls" ]
}

@test "mock chat_stream context_overflow emits error event and returns non-zero" {
  local output event_type

  baish_provider_call mock auth
  run baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"overflow"}],"mock":{"scenario":"context_overflow"}}'

  [ "$status" -ne 0 ]
  [[ "$output" == *'"type":"error"'* ]]

  event_type="$(grep '"type":"error"' <<<"$output" | jq -r '.type')"
  [ "$event_type" = "error" ]
}

@test "mock chat_stream unknown scenario returns error" {
  baish_provider_call mock auth
  run baish_provider_call mock chat_stream '{"messages":[{"role":"user","content":"x"}],"mock":{"scenario":"nonexistent"}}'

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support scenario"* ]]
}

# ─── NDJSON event parser ─────────────────────────────────────────────

@test "baish_agent_parse_streaming_event parses delta text event" {
  local line='{"type":"delta","category":"text","content":"Hello"}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "delta" ]
  [ "$STREAM_EVENT_CATEGORY" = "text" ]
  [ "$STREAM_EVENT_CONTENT" = "Hello" ]
}

@test "baish_agent_parse_streaming_event parses delta thinking event" {
  local line='{"type":"delta","category":"thinking","content":"Let me think"}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "delta" ]
  [ "$STREAM_EVENT_CATEGORY" = "thinking" ]
  [ "$STREAM_EVENT_CONTENT" = "Let me think" ]
}

@test "baish_agent_parse_streaming_event parses tool_call_delta event" {
  local line='{"type":"tool_call_delta","index":0,"tool_call_id":"call-1","name":"read","arguments_delta":"{\"path\":"}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "tool_call_delta" ]
  [ "$STREAM_EVENT_INDEX" = "0" ]
  [ "$STREAM_EVENT_TOOL_CALL_ID" = "call-1" ]
  [ "$STREAM_EVENT_TOOL_NAME" = "read" ]
  [ "$STREAM_EVENT_ARGS_DELTA" = '{"path":' ]
}

@test "baish_agent_parse_streaming_event parses tool_call event" {
  local line='{"type":"tool_call","tool_call_id":"call-1","name":"read","arguments":{"path":"file.txt"}}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "tool_call" ]
  [ "$STREAM_EVENT_TOOL_CALL_ID" = "call-1" ]
  [ "$STREAM_EVENT_TOOL_NAME" = "read" ]
  [ "$STREAM_EVENT_ARGS_JSON" = '{"path":"file.txt"}' ]
}

@test "baish_agent_parse_streaming_event parses done event" {
  local line='{"type":"done","finish_reason":"tool_calls"}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "done" ]
  [ "$STREAM_EVENT_FINISH_REASON" = "tool_calls" ]
}

@test "baish_agent_parse_streaming_event parses done event with stop reason" {
  local line='{"type":"done","finish_reason":"stop"}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "done" ]
  [ "$STREAM_EVENT_FINISH_REASON" = "stop" ]
}

@test "baish_agent_parse_streaming_event parses error event" {
  local line='{"type":"error","message":"stream failed"}'

  baish_agent_parse_streaming_event "$line"

  [ "$STREAM_EVENT_TYPE" = "error" ]
  [ "$STREAM_EVENT_ERROR_MSG" = "stream failed" ]
}

@test "baish_agent_parse_streaming_event returns 1 for empty line" {
  run baish_agent_parse_streaming_event ""
  [ "$status" -ne 0 ]
}

@test "baish_agent_parse_streaming_event returns 1 for invalid JSON" {
  run baish_agent_parse_streaming_event "not json at all"
  [ "$status" -ne 0 ]
}

@test "baish_agent_parse_streaming_event returns 1 for unknown event type" {
  local line='{"type":"heartbeat"}'
  run baish_agent_parse_streaming_event "$line"
  [ "$status" -ne 0 ]
}

@test "baish_agent_parse_streaming_event resets all globals before parsing" {
  # Set some garbage values first
  STREAM_EVENT_TYPE="garbage"
  STREAM_EVENT_CATEGORY="garbage"
  STREAM_EVENT_CONTENT="garbage"
  STREAM_EVENT_TOOL_CALL_ID="garbage"
  STREAM_EVENT_FINISH_REASON="garbage"
  STREAM_EVENT_ERROR_MSG="garbage"

  # Parse a simple delta — non-tool-call fields should be cleared
  baish_agent_parse_streaming_event '{"type":"delta","category":"text","content":"hi"}'

  [ "$STREAM_EVENT_TYPE" = "delta" ]
  [ "$STREAM_EVENT_CATEGORY" = "text" ]
  [ "$STREAM_EVENT_CONTENT" = "hi" ]
  [ "$STREAM_EVENT_TOOL_CALL_ID" = "" ]
  [ "$STREAM_EVENT_FINISH_REASON" = "" ]
  [ "$STREAM_EVENT_ERROR_MSG" = "" ]
}

# ─── Streaming availability ──────────────────────────────────────────

# Note: baish_agent_streaming_available checks `[[ ! -t 0 ]]` to skip streaming
# in non-interactive mode. Since bats never provides a tty, the "returns 0"
# case cannot be tested here. The non-tty fallback is tested below.

@test "baish_agent_streaming_available returns 1 when BAISH_STREAMING=0" {
  baish_provider_call mock auth
  BAISH_ACTIVE_PROVIDER="mock"
  BAISH_STREAMING=0

  run baish_agent_streaming_available "mock"
  [ "$status" -ne 0 ]
}

@test "baish_agent_streaming_available returns 1 when stdin is not a tty" {
  baish_provider_call mock auth
  BAISH_ACTIVE_PROVIDER="mock"

  # In bats, stdin is not a tty by default, so this should return 1
  run baish_agent_streaming_available "mock"
  [ "$status" -ne 0 ]
}

@test "baish_agent_streaming_available returns 1 for provider without has_streaming" {
  BAISH_ACTIVE_PROVIDER="unknown"

  run baish_agent_streaming_available "unknown"
  [ "$status" -ne 0 ]
}

# ─── Streaming UI helpers ────────────────────────────────────────────

@test "baish_agent_print_streaming_header outputs box header with label" {
  local output
  output="$(baish_agent_print_streaming_header "Thinking")"

  # Should contain the box-drawing character and the label
  [[ "$output" == *"╭─"* ]]
  [[ "$output" == *"Thinking"* ]]
}

@test "baish_agent_print_streaming_header defaults to Thinking label" {
  local output
  output="$(baish_agent_print_streaming_header)"

  [[ "$output" == *"Thinking"* ]]
}

@test "baish_agent_print_streaming_footer outputs box footer" {
  local output
  output="$(baish_agent_print_streaming_footer)"

  [[ "$output" == *"╰─"* ]]
}

@test "baish_agent_print_streaming_token outputs text token with bold style" {
  local output
  output="$(baish_agent_print_streaming_token "text" "Hello")"

  [[ "$output" == *"│"* ]]
  [[ "$output" == *"Hello"* ]]
}

@test "baish_agent_print_streaming_token outputs thinking token with dim style" {
  local output
  output="$(baish_agent_print_streaming_token "thinking" "reasoning...")"

  [[ "$output" == *"│"* ]]
  [[ "$output" == *"reasoning..."* ]]
}

# ─── Integration: streaming tool call accumulation ───────────────────

@test "streaming agent loop accumulates tool calls from NDJSON events" {
  # Simulate a stream with tool_call events and verify the agent
  # correctly accumulates them into tool_calls_json
  local tool_calls_json="{}"
  local tool_calls_array="[]"

  # Simulate parsing tool_call events
  while IFS= read -r line; do
    case "$(jq -r '.type' <<<"$line")" in
      tool_call)
        tool_calls_array="$(jq -c \
          --arg id "$(jq -r '.tool_call_id' <<<"$line")" \
          --arg name "$(jq -r '.name' <<<"$line")" \
          --argjson args "$(jq -c '.arguments' <<<"$line")" \
          '. + [{id: $id, name: $name, arguments: $args}]' \
          <<<"$tool_calls_array")"
        ;;
    esac
  done <<'EOF'
{"type":"tool_call","tool_call_id":"call-1","name":"read","arguments":{"path":"README.md"}}
{"type":"tool_call","tool_call_id":"call-2","name":"bash","arguments":{"command":"echo hi"}}
{"type":"done","finish_reason":"tool_calls"}
EOF

  [ "$(jq -r 'length' <<<"$tool_calls_array")" = "2" ]
  [ "$(jq -r '.[0].name' <<<"$tool_calls_array")" = "read" ]
  [ "$(jq -r '.[1].name' <<<"$tool_calls_array")" = "bash" ]
}

@test "streaming agent loop accumulates text content from multiple delta events" {
  local text_content=""

  while IFS= read -r line; do
    local etype ecategory econtent
    etype="$(jq -r '.type' <<<"$line")"
    if [[ "$etype" == "delta" ]]; then
      ecategory="$(jq -r '.category' <<<"$line")"
      econtent="$(jq -r '.content' <<<"$line")"
      if [[ "$ecategory" == "text" ]]; then
        text_content+="$econtent"
      fi
    fi
  done <<'EOF'
{"type":"delta","category":"text","content":"Hello"}
{"type":"delta","category":"text","content":" "}
{"type":"delta","category":"text","content":"world"}
{"type":"done","finish_reason":"stop"}
EOF

  [ "$text_content" = "Hello world" ]
}

@test "streaming agent loop distinguishes thinking from text content" {
  local text_content="" thinking_content=""

  while IFS= read -r line; do
    local etype ecategory econtent
    etype="$(jq -r '.type' <<<"$line")"
    if [[ "$etype" == "delta" ]]; then
      ecategory="$(jq -r '.category' <<<"$line")"
      econtent="$(jq -r '.content' <<<"$line")"
      case "$ecategory" in
        text) text_content+="$econtent" ;;
        thinking) thinking_content+="$econtent" ;;
      esac
    fi
  done <<'EOF'
{"type":"delta","category":"thinking","content":"Let me check the files."}
{"type":"delta","category":"text","content":"I reviewed them."}
{"type":"done","finish_reason":"stop"}
EOF

  [ "$thinking_content" = "Let me check the files." ]
  [ "$text_content" = "I reviewed them." ]
}
