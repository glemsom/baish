#!/usr/bin/env bash

provider_mock_metadata() {
  jq -cn '{"id": "mock", "label": "Mock Provider", "desc": "Offline provider for local demos and tests", "selectable": true}'
}

provider_mock_auth() {
  baish_state_write_auth_json 'mock' '{"provider":"mock","authenticated":true}'
}

provider_mock_require_auth() {
  local auth_json

  auth_json="$(baish_state_read_auth_json 'mock')" || return 1

  if ! jq -e 'type == "object" and .authenticated == true' >/dev/null 2>&1 <<<"$auth_json"; then
    printf 'BAISH mock provider is not connected. Run /connect first.\n' >&2
    return 1
  fi
}

provider_mock_list_models() {
  provider_mock_require_auth || return 1

  jq -cn '
    [
      {id: "mock-text", label: "Mock Text"},
      {id: "mock-tools", label: "Mock Tools"},
      {id: "mock-loop", label: "Mock Loop"}
    ]
  '
}

provider_mock_response_text() {
  local text="$1"
  local phase="${2-}"

  if [[ -n "$phase" ]]; then
    jq -cn --arg text "$text" --arg phase "$phase" '{assistant_text: $text, tool_calls: [], phase: $phase}'
  else
    jq -cn --arg text "$text" '{assistant_text: $text, tool_calls: []}'
  fi
}

provider_mock_response_tools() {
  local tool_calls_json="$1"
  local phase="${2-}"

  if [[ -n "$phase" ]]; then
    jq -cn --argjson tool_calls "$tool_calls_json" --arg phase "$phase" '{assistant_text: null, tool_calls: $tool_calls, phase: $phase}'
  else
    jq -cn --argjson tool_calls "$tool_calls_json" '{assistant_text: null, tool_calls: $tool_calls}'
  fi
}

provider_mock_tool_message_count() {
  local request_json="$1"

  jq -r '[.messages[]? | select(.role == "tool")] | length' <<<"$request_json"
}

provider_mock_chat_simple_text() {
  local request_json="$1"
  local final_text

  final_text="$(jq -r '.mock.final_text // env.BAISH_MOCK_FINAL_TEXT // "Mock assistant response."' <<<"$request_json")" || return 1
  provider_mock_response_text "$final_text"
}

provider_mock_chat_single_tool_then_final() {
  local request_json="$1"
  local tool_message_count command tool_calls_json final_text

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    command="$(jq -r '.mock.command // env.BAISH_MOCK_COMMAND // "printf mock-single-tool"' <<<"$request_json")" || return 1
    tool_calls_json="$(jq -cn --arg command "$command" '
      [
        {
          id: "mock-call-1",
          name: "bash",
          arguments: {command: $command}
        }
      ]
    ')" || return 1
    provider_mock_response_tools "$tool_calls_json"
    return 0
  fi

  final_text="$(jq -r '
    first(.messages[]? | select(.role == "tool")) as $tool_message
    | if ($tool_message.result.ok // false) == true then
        "Mock completed the single-tool scenario."
      else
        "Mock observed a tool error in the single-tool scenario."
      end
  ' <<<"$request_json")" || return 1

  provider_mock_response_text "$final_text"
}

provider_mock_chat_multiple_tools_then_final() {
  local request_json="$1"
  local tool_message_count first_command second_command tool_calls_json final_text

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    first_command="$(jq -r '.mock.first_command // env.BAISH_MOCK_FIRST_COMMAND // "printf first-tool"' <<<"$request_json")" || return 1
    second_command="$(jq -r '.mock.second_command // env.BAISH_MOCK_SECOND_COMMAND // "printf second-tool >&2; exit 3"' <<<"$request_json")" || return 1
    tool_calls_json="$(jq -cn --arg first "$first_command" --arg second "$second_command" '
      [
        {
          id: "mock-call-1",
          name: "bash",
          arguments: {command: $first}
        },
        {
          id: "mock-call-2",
          name: "bash",
          arguments: {command: $second}
        }
      ]
    ')" || return 1
    provider_mock_response_tools "$tool_calls_json"
    return 0
  fi

  final_text="$(jq -r '
    [ .messages[]? | select(.role == "tool") ] as $tool_messages
    | "Mock completed \(($tool_messages | length)) tool calls."
  ' <<<"$request_json")" || return 1

  provider_mock_response_text "$final_text"
}

provider_mock_chat_read_only_then_final() {
  local request_json="$1"
  local tool_message_count read_paths_json tool_calls_json final_text phase

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1
  phase="$(jq -r '.mock.phase // env.BAISH_MOCK_PHASE // ""' <<<"$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    read_paths_json="$(jq -c '(.mock.read_paths // (try (env.BAISH_MOCK_READ_PATHS_JSON | fromjson) catch null) // ["README.md"])' <<<"$request_json")" || return 1
    tool_calls_json="$(jq -cn --argjson read_paths "$read_paths_json" '
      $read_paths
      | to_entries
      | map({
          id: ("mock-read-call-" + ((.key + 1) | tostring)),
          name: "read",
          arguments: {path: .value}
        })
    ')" || return 1
    provider_mock_response_tools "$tool_calls_json" "$phase"
    return 0
  fi

  final_text="$(jq -r '.mock.final_text // env.BAISH_MOCK_FINAL_TEXT // "Mock completed the read-only scenario."' <<<"$request_json")" || return 1
  provider_mock_response_text "$final_text"
}

provider_mock_chat_mixed_read_bash_then_final() {
  local request_json="$1"
  local tool_message_count read_paths_json command tool_calls_json final_text phase

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1
  phase="$(jq -r '.mock.phase // env.BAISH_MOCK_PHASE // ""' <<<"$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    read_paths_json="$(jq -c '(.mock.read_paths // (try (env.BAISH_MOCK_READ_PATHS_JSON | fromjson) catch null) // ["README.md"])' <<<"$request_json")" || return 1
    command="$(jq -r '.mock.command // env.BAISH_MOCK_COMMAND // "printf mixed-tool-output"' <<<"$request_json")" || return 1
    tool_calls_json="$(jq -cn --argjson read_paths "$read_paths_json" --arg command "$command" '
      (
        $read_paths
        | to_entries
        | map({
            id: ("mock-read-call-" + ((.key + 1) | tostring)),
            name: "read",
            arguments: {path: .value}
          })
      )
      + [
          {
            id: "mock-bash-call-1",
            name: "bash",
            arguments: {command: $command}
          }
        ]
    ')" || return 1
    provider_mock_response_tools "$tool_calls_json" "$phase"
    return 0
  fi

  final_text="$(jq -r '.mock.final_text // env.BAISH_MOCK_FINAL_TEXT // "Mock completed the mixed tool scenario."' <<<"$request_json")" || return 1
  provider_mock_response_text "$final_text"
}

provider_mock_chat_loop_forever() {
  local request_json="$1"
  local command tool_calls_json

  command="$(jq -r '.mock.command // env.BAISH_MOCK_COMMAND // "printf mock-loop"' <<<"$request_json")" || return 1
  tool_calls_json="$(jq -cn --arg command "$command" '
    [
      {
        id: "mock-loop-call",
        name: "bash",
        arguments: {command: $command}
      }
    ]
  ')" || return 1

  provider_mock_response_tools "$tool_calls_json"
}

provider_mock_chat_context_overflow() {
  printf 'mock provider context window exceeded\n' >&2
  return 1
}

provider_mock_has_streaming() {
  printf 'true'
}

provider_mock_chat_stream() {
  local request_json="$1"
  local scenario

  provider_mock_require_auth || return 1

  if ! jq -e '
    type == "object"
    and ((.messages? == null) or (.messages | type == "array"))
    and ((.mock? == null) or (.mock | type == "object"))
  ' >/dev/null 2>&1 <<<"$request_json"; then
    printf 'BAISH mock provider requires a JSON object request.\n' >&2
    return 1
  fi

  scenario="$(jq -r '.mock.scenario // env.BAISH_MOCK_SCENARIO // "simple_text"' <<<"$request_json")" || return 1

  case "$scenario" in
    simple_text)
      _provider_mock_stream_simple_text "$request_json"
      ;;
    single_tool_then_final)
      _provider_mock_stream_single_tool_then_final "$request_json"
      ;;
    multiple_tools_then_final)
      _provider_mock_stream_multiple_tools_then_final "$request_json"
      ;;
    read_only_then_final)
      _provider_mock_stream_read_only_then_final "$request_json"
      ;;
    mixed_read_bash_then_final)
      _provider_mock_stream_mixed_read_bash_then_final "$request_json"
      ;;
    loop_forever)
      _provider_mock_stream_loop_forever "$request_json"
      ;;
    context_overflow)
      printf '%s\n' '{"type":"error","message":"mock provider context window exceeded"}'
      return 1
      ;;
    *)
      printf 'BAISH mock provider does not support scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac
}

# Helper: emit a single NDJSON delta event with a small sleep
_mock_emit_delta() {
  local category="$1"
  local content="$2"
  printf '%s\n' "{\"type\":\"delta\",\"category\":\"${category}\",\"content\":\"${content}\"}"
  sleep 0.02
}

# Helper: emit a tool_call_delta event with proper JSON escaping
_mock_emit_tool_call_delta() {
  local index="$1"
  local tool_call_id="$2"
  local name="$3"
  local arguments_delta="$4"
  # Use jq to properly JSON-encode the arguments_delta string value
  local encoded_delta
  encoded_delta="$(printf '%s' "$arguments_delta" | jq -Rs '.')" || return 1
  printf '{"type":"tool_call_delta","index":%s,"tool_call_id":"%s","name":"%s","arguments_delta":%s}\n' \
    "$index" "$tool_call_id" "$name" "$encoded_delta"
  sleep 0.02
}

# Helper: emit a complete tool_call event
_mock_emit_tool_call() {
  local tool_call_id="$1"
  local name="$2"
  local arguments_json="$3"
  printf '%s\n' "{\"type\":\"tool_call\",\"tool_call_id\":\"${tool_call_id}\",\"name\":\"${name}\",\"arguments\":${arguments_json}}"
  sleep 0.02
}

# Helper: emit a done event
_mock_emit_done() {
  local finish_reason="$1"
  printf '%s\n' "{\"type\":\"done\",\"finish_reason\":\"${finish_reason}\"}"
}

# Streaming: simple_text — emit text deltas then done
_provider_mock_stream_simple_text() {
  local request_json="$1"
  local final_text

  final_text="$(jq -r '.mock.final_text // env.BAISH_MOCK_FINAL_TEXT // "Mock assistant response."' <<<"$request_json")" || return 1

  # Emit the text character-by-character in small chunks to simulate tokenization,
  # preserving spaces so the assembled text matches the original.
  local i=0 chunk_size=3 len=${#final_text}
  while (( i < len )); do
    local chunk="${final_text:$i:$chunk_size}"
    _mock_emit_delta "text" "$chunk"
    (( i += chunk_size ))
  done

  _mock_emit_done "stop"
}

# Streaming: single_tool_then_final
_provider_mock_stream_single_tool_then_final() {
  local request_json="$1"
  local tool_message_count command

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    command="$(jq -r '.mock.command // env.BAISH_MOCK_COMMAND // "printf mock-single-tool"' <<<"$request_json")" || return 1

    _mock_emit_delta "text" "I'll"
    _mock_emit_delta "text" "run"
    _mock_emit_delta "text" "that"
    _mock_emit_delta "text" "command."

    # Stream tool call arguments character-by-character for the command
    local escaped_command
    escaped_command="$(jq -cn --arg c "$command" '$c' | sed 's/^"//;s/"$//')"
    _mock_emit_tool_call_delta 0 "mock-call-1" "bash" "{\"command\":\""

    # Emit arguments in small chunks
    local i=0 chunk_size=8 len=${#escaped_command}
    while (( i < len )); do
      local chunk="${escaped_command:$i:$chunk_size}"
      _mock_emit_tool_call_delta 0 "mock-call-1" "bash" "$chunk"
      (( i += chunk_size ))
    done

    _mock_emit_tool_call_delta 0 "mock-call-1" "bash" "\"}"

    _mock_emit_tool_call "mock-call-1" "bash" "{\"command\":\"${command}\"}"
    _mock_emit_done "tool_calls"
    return 0
  fi

  local final_text
  final_text="$(jq -r '
    first(.messages[]? | select(.role == "tool")) as $tool_message
    | if ($tool_message.result.ok // false) == true then
        "Mock completed the single-tool scenario."
      else
        "Mock observed a tool error in the single-tool scenario."
      end
  ' <<<"$request_json")" || return 1

  local -a words
  read -ra words <<<"$final_text"
  for word in "${words[@]}"; do
    _mock_emit_delta "text" "$word"
  done

  _mock_emit_done "stop"
}

# Streaming: multiple_tools_then_final
_provider_mock_stream_multiple_tools_then_final() {
  local request_json="$1"
  local tool_message_count first_command second_command

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    first_command="$(jq -r '.mock.first_command // env.BAISH_MOCK_FIRST_COMMAND // "printf first-tool"' <<<"$request_json")" || return 1
    second_command="$(jq -r '.mock.second_command // env.BAISH_MOCK_SECOND_COMMAND // "printf second-tool >&2; exit 3"' <<<"$request_json")" || return 1

    _mock_emit_delta "text" "Running"
    _mock_emit_delta "text" "both"
    _mock_emit_delta "text" "commands."

    # Tool call 1
    local escaped_first
    escaped_first="$(jq -cn --arg c "$first_command" '$c' | sed 's/^"//;s/"$//')"
    _mock_emit_tool_call_delta 0 "mock-call-1" "bash" "{\"command\":\"${escaped_first}\"}"
    _mock_emit_tool_call "mock-call-1" "bash" "{\"command\":\"${first_command}\"}"

    # Tool call 2
    local escaped_second
    escaped_second="$(jq -cn --arg c "$second_command" '$c' | sed 's/^"//;s/"$//')"
    _mock_emit_tool_call_delta 1 "mock-call-2" "bash" "{\"command\":\"${escaped_second}\"}"
    _mock_emit_tool_call "mock-call-2" "bash" "{\"command\":\"${second_command}\"}"

    _mock_emit_done "tool_calls"
    return 0
  fi

  local final_text
  final_text="$(jq -r '
    [ .messages[]? | select(.role == "tool") ] as $tool_messages
    | "Mock completed \(($tool_messages | length)) tool calls."
  ' <<<"$request_json")" || return 1

  local -a words
  read -ra words <<<"$final_text"
  for word in "${words[@]}"; do
    _mock_emit_delta "text" "$word"
  done

  _mock_emit_done "stop"
}

# Streaming: read_only_then_final
_provider_mock_stream_read_only_then_final() {
  local request_json="$1"
  local tool_message_count read_paths_json phase

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1
  phase="$(jq -r '.mock.phase // env.BAISH_MOCK_PHASE // ""' <<<"$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    read_paths_json="$(jq -c '(.mock.read_paths // (try (env.BAISH_MOCK_READ_PATHS_JSON | fromjson) catch null) // ["README.md"])' <<<"$request_json")" || return 1

    _mock_emit_delta "text" "Let"
    _mock_emit_delta "text" "me"
    _mock_emit_delta "text" "read"
    _mock_emit_delta "text" "those"
    _mock_emit_delta "text" "files."

    local index=0
    while IFS= read -r path; do
      local call_id="mock-read-call-$((index + 1))"
      _mock_emit_tool_call_delta "$index" "$call_id" "read" "{\"path\":\"${path}\"}"
      _mock_emit_tool_call "$call_id" "read" "{\"path\":\"${path}\"}"
      (( index++ ))
    done < <(jq -r '.[]' <<<"$read_paths_json")

    _mock_emit_done "tool_calls"
    return 0
  fi

  local final_text
  final_text="$(jq -r '.mock.final_text // env.BAISH_MOCK_FINAL_TEXT // "Mock completed the read-only scenario."' <<<"$request_json")" || return 1

  local -a words
  read -ra words <<<"$final_text"
  for word in "${words[@]}"; do
    _mock_emit_delta "text" "$word"
  done

  _mock_emit_done "stop"
}

# Streaming: mixed_read_bash_then_final
_provider_mock_stream_mixed_read_bash_then_final() {
  local request_json="$1"
  local tool_message_count read_paths_json command phase

  tool_message_count="$(provider_mock_tool_message_count "$request_json")" || return 1
  phase="$(jq -r '.mock.phase // env.BAISH_MOCK_PHASE // ""' <<<"$request_json")" || return 1

  if (( tool_message_count == 0 )); then
    read_paths_json="$(jq -c '(.mock.read_paths // (try (env.BAISH_MOCK_READ_PATHS_JSON | fromjson) catch null) // ["README.md"])' <<<"$request_json")" || return 1
    command="$(jq -r '.mock.command // env.BAISH_MOCK_COMMAND // "printf mixed-tool-output"' <<<"$request_json")" || return 1

    _mock_emit_delta "text" "I'll"
    _mock_emit_delta "text" "read"
    _mock_emit_delta "text" "the"
    _mock_emit_delta "text" "files"
    _mock_emit_delta "text" "and"
    _mock_emit_delta "text" "run"
    _mock_emit_delta "text" "the"
    _mock_emit_delta "text" "command."

    local index=0
    while IFS= read -r path; do
      local call_id="mock-read-call-$((index + 1))"
      _mock_emit_tool_call_delta "$index" "$call_id" "read" "{\"path\":\"${path}\"}"
      _mock_emit_tool_call "$call_id" "read" "{\"path\":\"${path}\"}"
      (( index++ ))
    done < <(jq -r '.[]' <<<"$read_paths_json")

    local bash_call_id="mock-bash-call-1"
    local escaped_command
    escaped_command="$(jq -cn --arg c "$command" '$c' | sed 's/^"//;s/"$//')"
    _mock_emit_tool_call_delta "$index" "$bash_call_id" "bash" "{\"command\":\"${escaped_command}\"}"
    _mock_emit_tool_call "$bash_call_id" "bash" "{\"command\":\"${command}\"}"

    _mock_emit_done "tool_calls"
    return 0
  fi

  local final_text
  final_text="$(jq -r '.mock.final_text // env.BAISH_MOCK_FINAL_TEXT // "Mock completed the mixed tool scenario."' <<<"$request_json")" || return 1

  local -a words
  read -ra words <<<"$final_text"
  for word in "${words[@]}"; do
    _mock_emit_delta "text" "$word"
  done

  _mock_emit_done "stop"
}

# Streaming: loop_forever
_provider_mock_stream_loop_forever() {
  local request_json="$1"
  local command

  command="$(jq -r '.mock.command // env.BAISH_MOCK_COMMAND // "printf mock-loop"' <<<"$request_json")" || return 1

  local escaped_command
  escaped_command="$(jq -cn --arg c "$command" '$c' | sed 's/^"//;s/"$//')"
  _mock_emit_tool_call_delta 0 "mock-loop-call" "bash" "{\"command\":\"${escaped_command}\"}"
  _mock_emit_tool_call "mock-loop-call" "bash" "{\"command\":\"${command}\"}"

  _mock_emit_done "tool_calls"
}

provider_mock_chat() {
  local request_json="$1"
  local scenario

  provider_mock_require_auth || return 1

  if ! jq -e '
    type == "object"
    and ((.messages? == null) or (.messages | type == "array"))
    and ((.mock? == null) or (.mock | type == "object"))
  ' >/dev/null 2>&1 <<<"$request_json"; then
    printf 'BAISH mock provider requires a JSON object request.\n' >&2
    return 1
  fi

  scenario="$(jq -r '.mock.scenario // env.BAISH_MOCK_SCENARIO // "simple_text"' <<<"$request_json")" || return 1

  case "$scenario" in
    simple_text)
      provider_mock_chat_simple_text "$request_json"
      ;;
    single_tool_then_final)
      provider_mock_chat_single_tool_then_final "$request_json"
      ;;
    multiple_tools_then_final)
      provider_mock_chat_multiple_tools_then_final "$request_json"
      ;;
    read_only_then_final)
      provider_mock_chat_read_only_then_final "$request_json"
      ;;
    mixed_read_bash_then_final)
      provider_mock_chat_mixed_read_bash_then_final "$request_json"
      ;;
    loop_forever)
      provider_mock_chat_loop_forever "$request_json"
      ;;
    context_overflow)
      provider_mock_chat_context_overflow
      ;;
    *)
      printf 'BAISH mock provider does not support scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac
}
