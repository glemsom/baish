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

baish_agent_tail_lines() {
  local text="$1"
  local max_lines="$2"

  if [[ ! "$max_lines" =~ ^[0-9]+$ ]] || (( max_lines <= 0 )); then
    printf '%s' "$text"
    return 0
  fi

  printf '%s' "$text" | tail -n "$max_lines"
}

baish_agent_bash_output_preview() {
  local stdout_text="$1"
  local stderr_text="$2"
  local preview='' stdout_preview stderr_preview

  if [[ -n "$stdout_text" ]]; then
    stdout_preview="$(baish_agent_tail_lines "$stdout_text" 10)" || return 1
    preview="$stdout_preview"
  fi

  if [[ -n "$stderr_text" ]]; then
    stderr_preview="$(baish_agent_tail_lines "$stderr_text" 10)" || return 1
    if [[ -n "$preview" ]]; then
      preview+=$'\n''stderr:'$'\n'
      preview+="$stderr_preview"
    else
      preview='stderr:'$'\n'
      preview+="$stderr_preview"
    fi
  fi

  printf '%s' "$preview"
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
  local line_count replacements bytes action exit_code stdout_text stderr_text

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

      if [[ -n "$stdout_text" || -n "$stderr_text" ]]; then
        detail="$(baish_agent_bash_output_preview "$stdout_text" "$stderr_text")" || return 1
      fi

      if (( exit_code != 0 )); then
        status='failure'
        footer="bash failed (exit $exit_code)"
      elif [[ -n "$detail" ]]; then
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

