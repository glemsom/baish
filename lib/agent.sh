#!/usr/bin/env bash

baish_provider_chat_response_valid() {
  local response_json="$1"

  jq -e '
    type == "object"
    and has("assistant_text")
    and has("tool_calls")
    and ((.assistant_text == null) or (.assistant_text | type == "string"))
    and (.tool_calls | type == "array")
    and all(
      .tool_calls[];
      type == "object"
      and (.id? | type == "string" and length > 0)
      and (.name? | type == "string" and length > 0)
      and (.arguments? | type == "object")
    )
  ' >/dev/null 2>&1 <<<"$response_json"
}

baish_provider_chat_json() {
  local provider="$1"
  local request_json="$2"
  local response_json

  response_json="$(baish_provider_call "$provider" chat "$request_json")" || return 1

  if ! baish_provider_chat_response_valid "$response_json"; then
    printf 'BAISH provider %s returned an invalid chat response.\n' "$provider" >&2
    return 1
  fi

  printf '%s\n' "$response_json"
}

baish_agent_limit_value() {
  local raw_value="$1"
  local default_value="$2"

  if [[ "$raw_value" =~ ^[0-9]+$ ]] && (( raw_value > 0 )); then
    printf '%s\n' "$raw_value"
  else
    printf '%s\n' "$default_value"
  fi
}

baish_agent_append_message_json() {
  local message_json="$1"
  local normalized_message_json

  baish_session_init

  if ! jq -e '
    type == "object"
    and (.role? | type == "string" and length > 0)
  ' >/dev/null 2>&1 <<<"$message_json"; then
    printf 'BAISH session messages must be JSON objects with a role.\n' >&2
    return 1
  fi

  normalized_message_json="$(jq -c '.' <<<"$message_json")" || return 1
  BAISH_SESSION_MESSAGES+=("$normalized_message_json")
}

baish_agent_append_user_message() {
  local content="$1"
  local message_json

  message_json="$(jq -cn --arg content "$content" '{role: "user", content: $content}')" || return 1
  baish_agent_append_message_json "$message_json"
}

baish_agent_append_assistant_response() {
  local response_json="$1"
  local message_json

  message_json="$(jq -cn --argjson response "$response_json" '{role: "assistant", content: $response.assistant_text, tool_calls: $response.tool_calls}')" || return 1
  baish_agent_append_message_json "$message_json"
}

baish_agent_append_tool_result() {
  local tool_call_id="$1"
  local tool_name="$2"
  local result_json="$3"
  local message_json

  message_json="$(jq -cn \
    --arg tool_call_id "$tool_call_id" \
    --arg tool_name "$tool_name" \
    --argjson result "$result_json" \
    '{role: "tool", tool_call_id: $tool_call_id, name: $tool_name, result: $result}')" || return 1

  baish_agent_append_message_json "$message_json"
}

baish_agent_refresh_active_provider_model() {
  BAISH_ACTIVE_PROVIDER="$(baish_config_active_provider)" || return 1
  BAISH_ACTIVE_MODEL="$(baish_config_active_model)" || return 1
}

baish_agent_missing_connection() {
  local provider="$1"
  local model="$2"
  local auth_file

  if [[ -z "$provider" || -z "$model" ]]; then
    return 0
  fi

  auth_file="$(baish_state_auth_file "$provider")" || return 1
  if [[ ! -f "$auth_file" ]]; then
    return 0
  fi

  return 1
}

baish_agent_ensure_connection() {
  local provider model

  baish_agent_refresh_active_provider_model || return 1
  provider="$BAISH_ACTIVE_PROVIDER"
  model="$BAISH_ACTIVE_MODEL"

  if baish_agent_missing_connection "$provider" "$model"; then
    baish_connect_current_provider || return 1
    baish_agent_refresh_active_provider_model || return 1
  fi
}

baish_agent_provider_chat_capture() {
  local provider="$1"
  local request_json="$2"
  local stderr_file response_json status

  stderr_file="$(mktemp)" || return 1

  if response_json="$(baish_provider_call "$provider" chat "$request_json" 2>"$stderr_file")"; then
    BAISH_AGENT_PROVIDER_CHAT_STATUS=0
    BAISH_AGENT_PROVIDER_CHAT_STDERR="$(<"$stderr_file")"
    BAISH_AGENT_PROVIDER_CHAT_RESPONSE_JSON="$response_json"
    rm -f -- "$stderr_file"

    if ! baish_provider_chat_response_valid "$response_json"; then
      BAISH_AGENT_PROVIDER_CHAT_STATUS=1
      BAISH_AGENT_PROVIDER_CHAT_RESPONSE_JSON=''
      if [[ -n "$BAISH_AGENT_PROVIDER_CHAT_STDERR" ]]; then
        BAISH_AGENT_PROVIDER_CHAT_STDERR+=$'\n'
      fi
      BAISH_AGENT_PROVIDER_CHAT_STDERR+="BAISH provider $provider returned an invalid chat response."
      return 1
    fi

    return 0
  fi

  status=$?
  BAISH_AGENT_PROVIDER_CHAT_STATUS="$status"
  BAISH_AGENT_PROVIDER_CHAT_STDERR="$(<"$stderr_file")"
  BAISH_AGENT_PROVIDER_CHAT_RESPONSE_JSON=''
  rm -f -- "$stderr_file"
  return 1
}

baish_agent_provider_error_is_auth_issue() {
  local stderr_text="$1"

  grep -Eiq 'not connected|unauthorized|unauthenticated|authentication|invalid auth|bad credentials|requires authentication|forbidden|(^|[^0-9])401([^0-9]|$)|(^|[^0-9])403([^0-9]|$)' <<<"$stderr_text"
}

baish_agent_provider_error_is_context_overflow() {
  local stderr_text="$1"

  grep -Eiq 'context overflow|context window|context[_ -]?length|request too large|too many tokens|max(imum)? tokens|prompt too large|context_length_exceeded|prompt_tokens_exceeded' <<<"$stderr_text"
}

baish_agent_print_context_overflow_error() {
  printf '%s\n' 'BAISH could not continue because the tool output exceeded the model context window. Retry with a narrower command or ask BAISH to inspect a smaller file range.' >&2
}

baish_agent_print_provider_error() {
  local provider="$1"
  local stderr_text="$2"

  if [[ -n "$stderr_text" ]]; then
    printf '%s\n' "$stderr_text" >&2
  else
    printf 'BAISH provider %s chat request failed.\n' "$provider" >&2
  fi
}

baish_agent_run_user_message() {
  local user_text="$1"
  local provider model request_json response_json assistant_text
  local max_tool_rounds max_tool_calls reconnect_attempted=0 first_request=1
  local tool_rounds=0 tool_calls=0 tool_call_count
  local tool_call_json tool_call_id tool_name tool_arguments tool_result

  if [[ -z "$user_text" ]]; then
    return 0
  fi

  baish_session_init
  baish_agent_ensure_connection || return 1
  baish_agent_append_user_message "$user_text" || return 1

  max_tool_rounds="$(baish_agent_limit_value "${BAISH_MAX_TOOL_ROUNDS:-20}" 20)" || return 1
  max_tool_calls="$(baish_agent_limit_value "${BAISH_MAX_TOOL_CALLS:-100}" 100)" || return 1

  while true; do
    baish_agent_refresh_active_provider_model || return 1
    provider="$BAISH_ACTIVE_PROVIDER"
    model="$BAISH_ACTIVE_MODEL"

    request_json="$(baish_context_build_request_json "$model")" || return 1

    if ! baish_agent_provider_chat_capture "$provider" "$request_json"; then
      if (( first_request == 1 )) && (( reconnect_attempted == 0 )) && baish_agent_provider_error_is_auth_issue "$BAISH_AGENT_PROVIDER_CHAT_STDERR"; then
        baish_connect_current_provider || return 1
        reconnect_attempted=1
        continue
      fi

      if baish_agent_provider_error_is_context_overflow "$BAISH_AGENT_PROVIDER_CHAT_STDERR"; then
        baish_agent_print_context_overflow_error
        return 1
      fi

      baish_agent_print_provider_error "$provider" "$BAISH_AGENT_PROVIDER_CHAT_STDERR"
      return 1
    fi

    first_request=0
    response_json="$BAISH_AGENT_PROVIDER_CHAT_RESPONSE_JSON"
    assistant_text="$(jq -r '.assistant_text // ""' <<<"$response_json")" || return 1
    tool_call_count="$(jq -r '.tool_calls | length' <<<"$response_json")" || return 1

    baish_agent_append_assistant_response "$response_json" || return 1

    if [[ -n "$assistant_text" ]]; then
      printf 'assistant> %s\n' "$assistant_text"
    fi

    if (( tool_call_count == 0 )); then
      return 0
    fi

    if (( tool_rounds + 1 > max_tool_rounds )); then
      printf 'BAISH stopped because the max tool rounds limit (%s) was exceeded.\n' "$max_tool_rounds" >&2
      return 1
    fi
    tool_rounds=$(( tool_rounds + 1 ))

    while IFS= read -r tool_call_json; do
      [[ -z "$tool_call_json" ]] && continue

      if (( tool_calls + 1 > max_tool_calls )); then
        printf 'BAISH stopped because the max tool calls limit (%s) was exceeded.\n' "$max_tool_calls" >&2
        return 1
      fi
      tool_calls=$(( tool_calls + 1 ))

      tool_call_id="$(jq -r '.id' <<<"$tool_call_json")" || return 1
      tool_name="$(jq -r '.name' <<<"$tool_call_json")" || return 1
      tool_arguments="$(jq -c '.arguments' <<<"$tool_call_json")" || return 1

      printf 'tool> %s %s\n' "$tool_name" "$tool_arguments"
      tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")" || return 1
      printf 'tool_result> %s\n' "$tool_result"

      baish_agent_append_tool_result "$tool_call_id" "$tool_name" "$tool_result" || return 1
    done < <(jq -c '.tool_calls[]' <<<"$response_json")
  done
}
