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

baish_agent_style_reset() {
  printf '\033[0m'
}

baish_agent_style_dim() {
  printf '\033[2m'
}

baish_agent_style_cyan() {
  printf '\033[36m'
}

baish_agent_style_bold_white() {
  printf '\033[1;97m'
}

baish_agent_style_green() {
  printf '\033[32m'
}

baish_agent_style_red() {
  printf '\033[31m'
}

baish_agent_style_yellow() {
  printf '\033[33m'
}

baish_agent_tool_icon() {
  local tool_name="$1"

  case "$tool_name" in
    read)
      printf '📖\n'
      ;;
    edit)
      printf '✏️\n'
      ;;
    write)
      printf '📝\n'
      ;;
    bash)
      printf '⚙️\n'
      ;;
    *)
      printf '🛠️\n'
      ;;
  esac
}

baish_agent_normalize_preview_text() {
  local text="$1"

  printf '%s' "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

baish_agent_truncate_preview() {
  local text="$1"
  local max_width="$2"

  if [[ ! "$max_width" =~ ^[0-9]+$ ]] || (( max_width <= 0 )); then
    printf '%s\n' "$text"
    return 0
  fi

  if (( ${#text} > max_width )); then
    if (( max_width == 1 )); then
      printf '…\n'
    else
      printf '%s…\n' "${text:0:max_width-1}"
    fi
  else
    printf '%s\n' "$text"
  fi
}

baish_agent_first_non_empty_line() {
  local text="$1"

  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
      if (length(trimmed) > 0) {
        print trimmed
        exit
      }
    }
  ' <<<"$text"
}

baish_agent_count_label() {
  local count="$1"
  local singular="$2"
  local plural="$3"

  if [[ "$count" == '1' ]]; then
    printf '%s %s\n' "$count" "$singular"
  else
    printf '%s %s\n' "$count" "$plural"
  fi
}

baish_agent_summarize_tool_call() {
  local tool_name="$1"
  local arguments_json="$2"
  local path has_offset has_limit start limit end_line replacements command preview

  case "$tool_name" in
    read)
      if ! jq -e '
        type == "object"
        and (.path? | type == "string" and length > 0)
        and ((.offset? == null) or (.offset | type == "number" and floor == . and . >= 1))
        and ((.limit? == null) or (.limit | type == "number" and floor == . and . >= 0))
      ' >/dev/null 2>&1 <<<"$arguments_json"; then
        printf '[invalid arguments]\n'
        return 0
      fi

      path="$(jq -r '.path' <<<"$arguments_json")" || return 1
      has_offset="$(jq -r 'has("offset")' <<<"$arguments_json")" || return 1
      has_limit="$(jq -r 'has("limit")' <<<"$arguments_json")" || return 1

      if [[ "$has_offset" == 'true' || "$has_limit" == 'true' ]]; then
        start="$(jq -r 'if .offset == null then 1 else .offset end' <<<"$arguments_json")" || return 1
        if [[ "$has_limit" == 'true' ]]; then
          limit="$(jq -r '.limit' <<<"$arguments_json")" || return 1
          if (( limit == 0 )); then
            printf '%s:%s+\n' "$path" "$start"
          else
            end_line=$(( start + limit - 1 ))
            printf '%s:%s-%s\n' "$path" "$start" "$end_line"
          fi
        else
          printf '%s:%s+\n' "$path" "$start"
        fi
      else
        printf '%s\n' "$path"
      fi
      ;;
    edit)
      if ! jq -e '
        type == "object"
        and (.path? | type == "string" and length > 0)
        and (.edits? | type == "array")
      ' >/dev/null 2>&1 <<<"$arguments_json"; then
        printf '[invalid arguments]\n'
        return 0
      fi

      path="$(jq -r '.path' <<<"$arguments_json")" || return 1
      replacements="$(jq -r '.edits | length' <<<"$arguments_json")" || return 1
      printf '%s (%s)\n' "$path" "$(baish_agent_count_label "$replacements" 'replacement' 'replacements')"
      ;;
    write)
      if ! jq -e '
        type == "object"
        and (.path? | type == "string" and length > 0)
        and (.content? | type == "string")
      ' >/dev/null 2>&1 <<<"$arguments_json"; then
        printf '[invalid arguments]\n'
        return 0
      fi

      jq -r '.path' <<<"$arguments_json"
      ;;
    bash)
      if ! jq -e '
        type == "object"
        and (.command? | type == "string")
      ' >/dev/null 2>&1 <<<"$arguments_json"; then
        printf '[invalid arguments]\n'
        return 0
      fi

      command="$(jq -r '.command' <<<"$arguments_json")" || return 1
      preview="$(baish_agent_normalize_preview_text "$command")" || return 1
      baish_agent_truncate_preview "$preview" 100
      ;;
    *)
      printf '\n'
      ;;
  esac
}

baish_agent_summarize_tool_result() {
  local tool_name="$1"
  local result_json="$2"
  local status summary footer detail
  local line_count replacements bytes action exit_code stdout_text stderr_text preview_line

  if ! jq -e 'type == "object" and (.ok? | type == "boolean")' >/dev/null 2>&1 <<<"$result_json"; then
    jq -cn \
      --arg status 'failure' \
      --arg summary '' \
      --arg footer "$tool_name failed" \
      --arg detail 'invalid tool result' \
      '{status: $status, summary: $summary, footer: $footer, detail: $detail}'
    return 0
  fi

  if [[ "$(jq -r '.ok' <<<"$result_json")" != 'true' ]]; then
    footer="$tool_name failed"
    detail="$(jq -r '(.error.code // "tool_error") + (if (.error.message // "") == "" then "" else ": " + .error.message end)' <<<"$result_json")" || return 1
    detail="$(baish_agent_truncate_preview "$(baish_agent_normalize_preview_text "$detail")" 140)" || return 1
    jq -cn \
      --arg status 'failure' \
      --arg summary '' \
      --arg footer "$footer" \
      --arg detail "$detail" \
      '{status: $status, summary: $summary, footer: $footer, detail: $detail}'
    return 0
  fi

  status='success'
  summary='completed'
  footer='completed'
  detail=''

  case "$tool_name" in
    read)
      line_count="$(jq -r '.data.line_count // 0' <<<"$result_json")" || return 1
      summary="$(baish_agent_count_label "$line_count" 'line' 'lines')" || return 1
      ;;
    edit)
      replacements="$(jq -r '.data.replacements // 0' <<<"$result_json")" || return 1
      bytes="$(jq -r '.data.bytes // 0' <<<"$result_json")" || return 1
      summary="updated ($(baish_agent_count_label "$replacements" 'replacement' 'replacements' | tr -d '\n'), $bytes bytes)"
      ;;
    write)
      bytes="$(jq -r '.data.bytes // 0' <<<"$result_json")" || return 1
      if [[ "$(jq -r '.data.created // false' <<<"$result_json")" == 'true' ]]; then
        action='created'
      elif [[ "$(jq -r '.data.overwritten // false' <<<"$result_json")" == 'true' ]]; then
        action='overwritten'
      else
        action='wrote'
      fi
      summary="$action ($bytes bytes)"
      ;;
    bash)
      exit_code="$(jq -r '.data.exit_code // 0' <<<"$result_json")" || return 1
      stdout_text="$(jq -r '.data.stdout // ""' <<<"$result_json")" || return 1
      stderr_text="$(jq -r '.data.stderr // ""' <<<"$result_json")" || return 1

      if (( exit_code != 0 )); then
        status='failure'
        footer="bash failed (exit $exit_code)"
        preview_line="$(baish_agent_first_non_empty_line "$stderr_text")" || return 1
        if [[ -n "$preview_line" ]]; then
          detail="stderr: $(baish_agent_truncate_preview "$(baish_agent_normalize_preview_text "$preview_line")" 140)"
        else
          preview_line="$(baish_agent_first_non_empty_line "$stdout_text")" || return 1
          if [[ -n "$preview_line" ]]; then
            detail="stdout: $(baish_agent_truncate_preview "$(baish_agent_normalize_preview_text "$preview_line")" 140)"
          fi
        fi
      elif [[ -n "$stdout_text" || -n "$stderr_text" ]]; then
        summary='completed with output'
      else
        summary='completed (exit 0)'
      fi
      ;;
  esac

  jq -cn \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg footer "$footer" \
    --arg detail "$detail" \
    '{status: $status, summary: $summary, footer: $footer, detail: $detail}'
}

baish_agent_print_tool_round_start() {
  printf '%s╭─%s %sTools%s\n' \
    "$(baish_agent_style_dim)" \
    "$(baish_agent_style_reset)" \
    "$(baish_agent_style_cyan)" \
    "$(baish_agent_style_reset)"
}

baish_agent_print_tool_round_item() {
  local tool_name="$1"
  local summary="$2"
  local icon padded_name

  icon="$(baish_agent_tool_icon "$tool_name")" || return 1
  printf -v padded_name '%-5s' "$tool_name"

  if [[ -n "$summary" ]]; then
    printf '%s│%s %s%s %s%s%s\n' \
      "$(baish_agent_style_dim)" \
      "$(baish_agent_style_reset)" \
      "$(baish_agent_style_cyan)" \
      "$icon $padded_name" \
      "$(baish_agent_style_bold_white)" \
      "$summary" \
      "$(baish_agent_style_reset)"
  else
    printf '%s│%s %s%s%s\n' \
      "$(baish_agent_style_dim)" \
      "$(baish_agent_style_reset)" \
      "$(baish_agent_style_cyan)" \
      "$icon $tool_name" \
      "$(baish_agent_style_reset)"
  fi
}

baish_agent_print_tool_round_result_summary() {
  local summary="$1"

  printf '%s│%s   %s↳ %s%s\n' \
    "$(baish_agent_style_dim)" \
    "$(baish_agent_style_reset)" \
    "$(baish_agent_style_dim)" \
    "$summary" \
    "$(baish_agent_style_reset)"
}

baish_agent_print_tool_round_end() {
  local status="$1"
  local text="$2"
  local color icon

  case "$status" in
    success)
      color="$(baish_agent_style_green)"
      icon='✅'
      ;;
    warning)
      color="$(baish_agent_style_yellow)"
      icon='⚠️'
      ;;
    *)
      color="$(baish_agent_style_red)"
      icon='❌'
      ;;
  esac

  printf '%s╰─%s %s%s%s %s\n' \
    "$(baish_agent_style_dim)" \
    "$(baish_agent_style_reset)" \
    "$color" \
    "$icon" \
    "$(baish_agent_style_reset)" \
    "$text"
}

baish_agent_print_tool_round_detail() {
  local detail="$1"

  printf '   %s↳ %s%s\n' \
    "$(baish_agent_style_dim)" \
    "$detail" \
    "$(baish_agent_style_reset)"
}

baish_agent_run_user_message() {
  local user_text="$1"
  local provider model request_json response_json assistant_text
  local max_tool_rounds max_tool_calls reconnect_attempted=0 first_request=1
  local tool_rounds=0 tool_calls=0 tool_call_count
  local tool_call_json tool_call_id tool_name tool_arguments tool_result
  local tool_call_summary tool_result_summary_json tool_render_status tool_render_summary
  local tool_render_footer tool_render_detail round_status round_footer round_detail

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

    baish_agent_print_tool_round_start
    round_status='success'
    round_footer='completed'
    round_detail=''

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
      tool_call_summary="$(baish_agent_summarize_tool_call "$tool_name" "$tool_arguments")" || return 1

      baish_agent_print_tool_round_item "$tool_name" "$tool_call_summary"
      tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")" || return 1
      tool_result_summary_json="$(baish_agent_summarize_tool_result "$tool_name" "$tool_result")" || return 1
      tool_render_status="$(jq -r '.status' <<<"$tool_result_summary_json")" || return 1
      tool_render_summary="$(jq -r '.summary // ""' <<<"$tool_result_summary_json")" || return 1
      tool_render_footer="$(jq -r '.footer // ""' <<<"$tool_result_summary_json")" || return 1
      tool_render_detail="$(jq -r '.detail // ""' <<<"$tool_result_summary_json")" || return 1

      if [[ "$tool_render_status" == 'success' ]]; then
        if [[ -n "$tool_render_summary" ]]; then
          baish_agent_print_tool_round_result_summary "$tool_render_summary"
        fi
      elif [[ "$round_status" == 'success' ]]; then
        round_status='failure'
        round_footer="$tool_render_footer"
        round_detail="$tool_render_detail"
      fi

      baish_agent_append_tool_result "$tool_call_id" "$tool_name" "$tool_result" || return 1
    done < <(jq -c '.tool_calls[]' <<<"$response_json")

    baish_agent_print_tool_round_end "$round_status" "$round_footer"
    if [[ -n "$round_detail" ]]; then
      baish_agent_print_tool_round_detail "$round_detail"
    fi
  done
}
