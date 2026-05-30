# Provider validation, connection management, and error classification

baish_provider_chat_response_valid() {
  local response_json="$1"

  jq -e '
    type == "object"
    and has("assistant_text")
    and has("tool_calls")
    and ((.assistant_text == null) or (.assistant_text | type == "string"))
    and ((.phase? == null) or (.phase | type == "string" and length > 0))
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

  if declare -F baish_provider_has_env_auth >/dev/null 2>&1 && baish_provider_has_env_auth "$provider"; then
    return 1
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

