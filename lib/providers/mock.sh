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
