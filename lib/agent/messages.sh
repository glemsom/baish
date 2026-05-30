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
  baish_maybe_log_system_prompt

  if baish_transcript_log_enabled; then
    baish_transcript_log_event "user_message" "$(jq -cn --arg content "$content" '{content: $content}')" || true
  fi
}

baish_agent_append_assistant_response() {
  local response_json="$1"
  local message_json

  message_json="$(jq -cn --argjson response "$response_json" '
    {
      role: "assistant",
      content: $response.assistant_text,
      tool_calls: $response.tool_calls
    }
    + (if ($response.phase? // null) == null then {} else {phase: $response.phase} end)
  ')" || return 1
  baish_agent_append_message_json "$message_json"
  baish_maybe_log_system_prompt

  if baish_transcript_log_enabled; then
    baish_transcript_log_event "assistant_response" "$response_json" || true
  fi
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
  baish_maybe_log_system_prompt

  if baish_transcript_log_enabled; then
    baish_transcript_log_event "tool_result" "$(jq -cn \
      --arg tool_call_id "$tool_call_id" \
      --arg tool_name "$tool_name" \
      --argjson result "$result_json" \
      '{tool_call_id: $tool_call_id, tool_name: $tool_name, result: $result}')" || true
  fi
}

baish_maybe_log_system_prompt() {
  if baish_transcript_log_enabled; then
    # Check if system prompt already logged in this session
    if [[ -z "${BAISH_SESSION_TRANSCRIPT_SYSTEM_PROMPT_LOGGED:-}" ]]; then
      local base_prompt tool_use_instructions skills_json system_prompt_array
      base_prompt="$(baish_context_base_system_prompt)" || return 0
      tool_use_instructions="$(baish_context_tool_use_instructions)" || return 0
      skills_json="$(baish_context_skills_json)" || return 0
      system_prompt_array="$(jq -cn --arg base "$base_prompt" --arg tooluse "$tool_use_instructions" --argjson skills "$skills_json" '
  [
    {role: "system", content: $base},
    {role: "system", content: $tooluse}
  ] + ($skills | map({role: "system", content: ("Loaded skill: " + .name + "\n" + .content)}))
')" || return 0
      baish_transcript_log_event "system_prompt" "$system_prompt_array" || true
      BAISH_SESSION_TRANSCRIPT_SYSTEM_PROMPT_LOGGED=1
    fi
  fi
}