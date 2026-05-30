# ─── Streaming agent loop ────────────────────────────────────────────
# Mirrors baish_agent_run_user_message but consumes NDJSON events from
# the provider's chat_stream action instead of a synchronous response.

baish_agent_run_streaming() {
  local user_text="$1"
  local provider model request_json response_json
  local max_tool_rounds max_tool_calls reconnect_attempted=0 first_request=1
  local tool_rounds=0 tool_calls=0 tool_call_count
  local tool_call_json tool_call_id tool_name tool_arguments tool_result
  local tool_call_summary tool_result_summary_json tool_render_status tool_render_summary
  local tool_render_footer tool_render_detail round_status round_footer round_detail
  local round_phase_label read_paths_json read_paths_joined
  local stream_output stream_status stderr_file stderr_content
  local text_content thinking_content tool_calls_json finish_reason
  local tool_call_accumulators event_line

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

    # Reset per-round accumulators
    text_content=""
    thinking_content=""
    tool_calls_json="[]"
    finish_reason=""
    tool_call_accumulators="{}"

    # Capture stderr for error/auth detection
    stderr_file="$(mktemp)" || return 1

    stream_output="$(baish_provider_call "$provider" chat_stream "$request_json" 2>"$stderr_file")"
    stream_status=$?
    stderr_content="$(<"$stderr_file")"
    rm -f -- "$stderr_file"

    if (( stream_status != 0 )); then
      if (( first_request == 1 )) && (( reconnect_attempted == 0 )) && baish_agent_provider_error_is_auth_issue "$stderr_content"; then
        baish_connect_current_provider || return 1
        reconnect_attempted=1
        continue
      fi

      if baish_agent_provider_error_is_context_overflow "$stderr_content"; then
        baish_agent_print_context_overflow_error
        return 1
      fi

      baish_agent_print_provider_error "$provider" "$stderr_content"
      return 1
    fi

    first_request=0

    # Print streaming block header
    baish_agent_print_streaming_block "thinking"
    local stream_box_mode="thinking"

    # Parse NDJSON events as they arrive
    while IFS= read -r event_line; do
      [[ -z "$event_line" ]] && continue

      if baish_agent_parse_streaming_event "$event_line"; then
        case "$STREAM_EVENT_TYPE" in
          delta)
            case "$STREAM_EVENT_CATEGORY" in
              thinking)
                if [[ "$stream_box_mode" != "thinking" ]]; then
                  baish_agent_print_streaming_block "thinking"
                  stream_box_mode="thinking"
                fi
                thinking_content+="$STREAM_EVENT_CONTENT"
                baish_agent_print_streaming_token "thinking" "$STREAM_EVENT_CONTENT"
                ;;
              text)
                if [[ "$stream_box_mode" != "text" ]]; then
                  baish_agent_print_streaming_block "text"
                  stream_box_mode="text"
                fi
                text_content+="$STREAM_EVENT_CONTENT"
                baish_agent_print_streaming_token "text" "$STREAM_EVENT_CONTENT"
                ;;
            esac
            ;;
          tool_call_delta)
            # Accumulate arguments per tool call index
            tool_call_accumulators="$(jq -c \
              --arg idx "$STREAM_EVENT_INDEX" \
              --arg id "$STREAM_EVENT_TOOL_CALL_ID" \
              --arg name "$STREAM_EVENT_TOOL_NAME" \
              --arg delta "$STREAM_EVENT_ARGS_DELTA" \
              '.[$idx].tool_call_id = $id |
               .[$idx].name = $name |
               .[$idx].args = ((.[$idx].args // "") + $delta)' \
              <<<"$tool_call_accumulators" 2>/dev/null)" || true
            ;;
          tool_call)
            # Finalize a complete tool call
            tool_calls_json="$(jq -c \
              --arg id "$STREAM_EVENT_TOOL_CALL_ID" \
              --arg name "$STREAM_EVENT_TOOL_NAME" \
              --argjson args "$STREAM_EVENT_ARGS_JSON" \
              '. + [{id: $id, name: $name, arguments: $args}]' \
              <<<"$tool_calls_json" 2>/dev/null)" || true
            ;;
          done)
            finish_reason="$STREAM_EVENT_FINISH_REASON"
            break
            ;;
          error)
            printf 'BAISH streaming error: %s\n' "$STREAM_EVENT_ERROR_MSG" >&2
            return 1
            ;;
        esac
      fi
    done <<<"$stream_output"

    # No footer needed — separators mark section boundaries

    # Build response_json from accumulated content (same shape as non-streaming)
    response_json="$(jq -cn \
      --arg text "$text_content" \
      --argjson tool_calls "$tool_calls_json" \
      '{assistant_text: $text, tool_calls: $tool_calls}'
    )" || return 1

    # Append assistant response to session
    baish_agent_append_assistant_response "$response_json" || return 1

    tool_call_count="$(jq -r '.tool_calls | length' <<<"$response_json")" || return 1

    if (( tool_call_count == 0 )); then
      return 0
    fi

    if (( tool_rounds + 1 > max_tool_rounds )); then
      printf 'BAISH stopped because the max tool rounds limit (%s) was exceeded.\n' "$max_tool_rounds" >&2
      return 1
    fi
    tool_rounds=$(( tool_rounds + 1 ))

    # ── Tool execution (same flow as non-streaming) ──
    round_phase_label="$(baish_agent_phase_label "$response_json")" || return 1
    read_paths_json="$(baish_agent_collect_read_paths_json "$response_json")" || return 1
    read_paths_joined="$(baish_agent_join_paths_for_display "$read_paths_json")" || return 1

    baish_agent_print_phase_round_start "$round_phase_label"
    if [[ -n "$read_paths_joined" ]]; then
      baish_agent_print_phase_round_files "$read_paths_joined"
    fi

    round_status='success'
    round_footer='completed'
    round_detail=''
    has_non_read_tool=0

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

      if [[ "$tool_name" != 'read' ]]; then
        has_non_read_tool=1
        tool_call_summary="$(baish_agent_summarize_tool_call "$tool_name" "$tool_arguments")" || return 1
        baish_agent_print_tool_round_item "$tool_name" "$tool_call_summary"
      fi

      tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")" || return 1
      tool_result_summary_json="$(baish_agent_summarize_tool_result "$tool_name" "$tool_result")" || return 1
      tool_render_status="$(jq -r '.status' <<<"$tool_result_summary_json")" || return 1
      tool_render_summary="$(jq -r '.summary // ""' <<<"$tool_result_summary_json")" || return 1
      tool_render_footer="$(jq -r '.footer // ""' <<<"$tool_result_summary_json")" || return 1
      tool_render_detail="$(jq -r '.detail // ""' <<<"$tool_result_summary_json")" || return 1

      if [[ "$tool_name" != 'read' ]]; then
        if [[ -n "$tool_render_summary" ]]; then
          baish_agent_print_tool_round_result_summary "$tool_render_status" "$tool_render_summary"
        fi
        if [[ -n "$tool_render_detail" ]]; then
          baish_agent_print_tool_round_result_detail "$tool_render_detail"
        fi
      fi

      if [[ "$tool_render_status" != 'success' && "$round_status" == 'success' ]]; then
        round_status='failure'
        round_footer="$tool_render_footer"
        round_detail=''
      fi

      baish_agent_append_tool_result "$tool_call_id" "$tool_name" "$tool_result" || return 1
    done < <(jq -c '.tool_calls[]' <<<"$response_json")

    if (( has_non_read_tool == 0 )); then
      baish_agent_print_tool_round_end "$round_status" "$round_footer"
    fi
    if [[ -n "$round_detail" ]]; then
      baish_agent_print_tool_round_detail "$round_detail"
    fi

    # Loop continues for next round if finish_reason == "tool_calls"
  done
}

baish_agent_run_user_message() {
  local user_text="$1"
  local provider model request_json response_json assistant_text
  local max_tool_rounds max_tool_calls reconnect_attempted=0 first_request=1
  local tool_rounds=0 tool_calls=0 tool_call_count
  local tool_call_json tool_call_id tool_name tool_arguments tool_result
  local tool_call_summary tool_result_summary_json tool_render_status tool_render_summary
  local tool_render_footer tool_render_detail round_status round_footer round_detail
  local round_phase_label read_paths_json read_paths_joined

  if [[ -z "$user_text" ]]; then
    return 0
  fi

  baish_session_init
  baish_agent_ensure_connection || return 1

  # Dispatch to streaming path when available
  if baish_agent_streaming_available "$BAISH_ACTIVE_PROVIDER"; then
    baish_agent_run_streaming "$user_text"
    return $?
  fi

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
      baish_agent_print_assistant_response "$assistant_text"
    fi

    if (( tool_call_count == 0 )); then
      return 0
    fi

    if (( tool_rounds + 1 > max_tool_rounds )); then
      printf 'BAISH stopped because the max tool rounds limit (%s) was exceeded.\n' "$max_tool_rounds" >&2
      return 1
    fi
    tool_rounds=$(( tool_rounds + 1 ))

    round_phase_label="$(baish_agent_phase_label "$response_json")" || return 1
    read_paths_json="$(baish_agent_collect_read_paths_json "$response_json")" || return 1
    read_paths_joined="$(baish_agent_join_paths_for_display "$read_paths_json")" || return 1

    baish_agent_print_phase_round_start "$round_phase_label"
    if [[ -n "$read_paths_joined" ]]; then
      baish_agent_print_phase_round_files "$read_paths_joined"
    fi

    round_status='success'
    round_footer='completed'
    round_detail=''
    has_non_read_tool=0

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

      if [[ "$tool_name" != 'read' ]]; then
        has_non_read_tool=1
        tool_call_summary="$(baish_agent_summarize_tool_call "$tool_name" "$tool_arguments")" || return 1
        baish_agent_print_tool_round_item "$tool_name" "$tool_call_summary"
      fi

      tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")" || return 1
      tool_result_summary_json="$(baish_agent_summarize_tool_result "$tool_name" "$tool_result")" || return 1
      tool_render_status="$(jq -r '.status' <<<"$tool_result_summary_json")" || return 1
      tool_render_summary="$(jq -r '.summary // ""' <<<"$tool_result_summary_json")" || return 1
      tool_render_footer="$(jq -r '.footer // ""' <<<"$tool_result_summary_json")" || return 1
      tool_render_detail="$(jq -r '.detail // ""' <<<"$tool_result_summary_json")" || return 1

      if [[ "$tool_name" != 'read' ]]; then
        if [[ -n "$tool_render_summary" ]]; then
          baish_agent_print_tool_round_result_summary "$tool_render_status" "$tool_render_summary"
        fi
        if [[ -n "$tool_render_detail" ]]; then
          baish_agent_print_tool_round_result_detail "$tool_render_detail"
        fi
      fi

      if [[ "$tool_render_status" != 'success' && "$round_status" == 'success' ]]; then
        round_status='failure'
        round_footer="$tool_render_footer"
        round_detail=''
      fi

      baish_agent_append_tool_result "$tool_call_id" "$tool_name" "$tool_result" || return 1
    done < <(jq -c '.tool_calls[]' <<<"$response_json")

    if (( has_non_read_tool == 0 )); then
      baish_agent_print_tool_round_end "$round_status" "$round_footer"
    fi
    if [[ -n "$round_detail" ]]; then
      baish_agent_print_tool_round_detail "$round_detail"
    fi
  done
}
