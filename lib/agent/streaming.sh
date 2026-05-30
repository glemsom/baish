#   STREAM_EVENT_ARGS_JSON   — full arguments JSON object (tool_call)
#   STREAM_EVENT_FINISH_REASON — "stop" | "tool_calls" | "length" | "error" (done events)
#   STREAM_EVENT_ERROR_MSG  — error message (error events)

baish_agent_parse_streaming_event() {
  local line="$1"

  # Reset all globals before parsing
  STREAM_EVENT_TYPE=''
  STREAM_EVENT_CATEGORY=''
  STREAM_EVENT_CONTENT=''
  STREAM_EVENT_INDEX=''
  STREAM_EVENT_TOOL_CALL_ID=''
  STREAM_EVENT_TOOL_NAME=''
  STREAM_EVENT_ARGS_DELTA=''
  STREAM_EVENT_ARGS_JSON=''
  STREAM_EVENT_FINISH_REASON=''
  STREAM_EVENT_ERROR_MSG=''

  # Skip empty lines
  [[ -z "$line" ]] && return 1

  # Extract type field
  STREAM_EVENT_TYPE="$(jq -r '.type // empty' <<<"$line" 2>/dev/null)" || return 1
  [[ -z "$STREAM_EVENT_TYPE" ]] && return 1

  case "$STREAM_EVENT_TYPE" in
    delta)
      STREAM_EVENT_CATEGORY="$(jq -r '.category // empty' <<<"$line" 2>/dev/null)" || return 1
      STREAM_EVENT_CONTENT="$(jq -r '.content // empty' <<<"$line" 2>/dev/null)" || return 1
      ;;
    tool_call_delta)
      STREAM_EVENT_INDEX="$(jq -r '.index // empty' <<<"$line" 2>/dev/null)" || return 1
      STREAM_EVENT_TOOL_CALL_ID="$(jq -r '.tool_call_id // empty' <<<"$line" 2>/dev/null)" || return 1
      STREAM_EVENT_TOOL_NAME="$(jq -r '.name // empty' <<<"$line" 2>/dev/null)" || return 1
      STREAM_EVENT_ARGS_DELTA="$(jq -r '.arguments_delta // empty' <<<"$line" 2>/dev/null)" || return 1
      ;;
    tool_call)
      STREAM_EVENT_TOOL_CALL_ID="$(jq -r '.tool_call_id // empty' <<<"$line" 2>/dev/null)" || return 1
      STREAM_EVENT_TOOL_NAME="$(jq -r '.name // empty' <<<"$line" 2>/dev/null)" || return 1
      STREAM_EVENT_ARGS_JSON="$(jq -c '.arguments // {}' <<<"$line" 2>/dev/null)" || return 1
      ;;
    done)
      STREAM_EVENT_FINISH_REASON="$(jq -r '.finish_reason // empty' <<<"$line" 2>/dev/null)" || return 1
      ;;
    error)
      STREAM_EVENT_ERROR_MSG="$(jq -r '.message // empty' <<<"$line" 2>/dev/null)" || return 1
      ;;
    *)
      # Unknown event type — skip silently
      return 1
      ;;
  esac

  return 0
}



# ─── Streaming availability check ────────────────────────────────────

baish_agent_streaming_available() {
  local provider="$1"

  # Disabled via environment variable
  if [[ "${BAISH_STREAMING:-1}" == "0" ]]; then
    return 1
  fi

  # Non-interactive mode (piped stdin) falls back to non-streaming
  if [[ ! -t 0 ]]; then
    return 1
  fi

  # Check if provider implements has_streaming and returns true
  if declare -F "provider_${provider}_has_streaming" >/dev/null 2>&1; then
    local result
    result="$(provider_${provider}_has_streaming 2>/dev/null)" || return 1
    [[ "$result" == "true" ]]
    return $?
  fi

  return 1
}

# ─── Streaming agent loop ────────────────────────────────────────────
# Mirrors baish_agent_run_user_message but consumes NDJSON events from
# the provider's chat_stream action instead of a synchronous response.

