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

# ─── Separator helper ───────────────────────────────────────────────

baish_agent_print_separator() {
  local emoji="$1"
  local label="$2"
  local width term_width content_len pad_len

  width="$(baish_agent_terminal_width)" || return 1
  content_len=$(( 2 + 1 + ${#emoji} + 1 + ${#label} ))  # " 🤔 Thinking"
  pad_len=$(( width - content_len ))
  (( pad_len < 2 )) && pad_len=2

  printf '%s%s %s%s%s %s%s\n' \
    "$(baish_agent_style_dim)" \
    "$emoji" \
    "$(baish_agent_style_cyan)" \
    "$label" \
    "$(baish_agent_style_reset)" \
    "$(baish_agent_style_dim)" \
    "$(printf '─%.0s' $(seq 1 $pad_len))"
}

# ─── Streaming UI helpers ────────────────────────────────────────────

baish_agent_print_streaming_block() {
  local category="$1"   # "thinking" | "text"
  local emoji label

  case "$category" in
    thinking) emoji="🤔"; label="Thinking" ;;
    text)     emoji="💬"; label="Reply" ;;
  esac

  baish_agent_print_separator "$emoji" "$label"
}

baish_agent_print_streaming_token() {
  local category="$1"
  local content="$2"
  local style line

  case "$category" in
    thinking) style="$(baish_agent_style_dim)" ;;
    text)     style="$(baish_agent_style_bold_white)" ;;
  esac

  # Strip trailing newline (here-string adds its own)
  if [[ "${content: -1}" == $'\n' ]]; then
    content="${content%$'\n'}"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      printf '  %s%s%s\n' "$style" "$line" "$(baish_agent_style_reset)"
    else
      printf '\n'
    fi
  done <<<"$content"
}

# ─── Streaming NDJSON event parser ───────────────────────────────────
# Parses one NDJSON line and sets global variables for the caller.
# Globals set:
#   STREAM_EVENT_TYPE       — "delta" | "tool_call_delta" | "tool_call" | "done" | "error"
#   STREAM_EVENT_CATEGORY   — "text" | "thinking" (only for delta events)
#   STREAM_EVENT_CONTENT    — text content (only for delta events)
#   STREAM_EVENT_INDEX      — tool call index (for tool_call_delta)
#   STREAM_EVENT_TOOL_CALL_ID — tool call identifier
#   STREAM_EVENT_TOOL_NAME  — tool name
#   STREAM_EVENT_ARGS_DELTA  — incremental arguments (tool_call_delta)
#   STREAM_EVENT_ARGS_JSON   — full arguments JSON object (tool_call)
#   STREAM_EVENT_FINISH_REASON — "stop" | "tool_calls" | "length" | "error" (done events)
#   STREAM_EVENT_ERROR_MSG  — error message (error events)


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


baish_agent_terminal_width() {
  local width="${COLUMNS:-100}"

  if [[ ! "$width" =~ ^[0-9]+$ ]] || (( width < 40 )); then
    width=100
  fi

  printf '%s\n' "$width"
}


baish_agent_print_phase_round_start() {
  local phase_label="$1"
  baish_agent_print_separator "🔧" "Phase: $phase_label"
}

baish_agent_print_phase_round_files() {
  local joined_paths="$1"
  local width content_width item remaining current_line candidate
  local label='Files:'
  local continuation_label='      '
  local first_line=1

  if [[ -z "$joined_paths" ]]; then
    return 0
  fi

  width="$(baish_agent_terminal_width)" || return 1
  content_width=$(( width - 10 ))
  if (( content_width < 20 )); then
    content_width=20
  fi

  remaining="$joined_paths"
  current_line=''

  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == *', '* ]]; then
      item="${remaining%%, *}"
      remaining="${remaining#*, }"
    else
      item="$remaining"
      remaining=''
    fi

    if [[ -z "$current_line" ]]; then
      candidate="$item"
    else
      candidate="$current_line, $item"
    fi

    if (( ${#candidate} <= content_width )) || [[ -z "$current_line" ]]; then
      current_line="$candidate"
      continue
    fi

    if (( first_line == 1 )); then
      printf '  %s%s%s %s%s%s\n' \
        "$(baish_agent_style_cyan)" \
        "$label" \
        "$(baish_agent_style_reset)" \
        "$(baish_agent_style_bold_white)" \
        "$current_line" \
        "$(baish_agent_style_reset)"
      first_line=0
    else
      printf '  %s%s%s %s%s%s\n' \
        "$(baish_agent_style_cyan)" \
        "$continuation_label" \
        "$(baish_agent_style_reset)" \
        "$(baish_agent_style_bold_white)" \
        "$current_line" \
        "$(baish_agent_style_reset)"
    fi

    current_line="$item"
  done

  if (( first_line == 1 )); then
    printf '  %s%s%s %s%s%s\n' \
      "$(baish_agent_style_cyan)" \
      "$label" \
      "$(baish_agent_style_reset)" \
      "$(baish_agent_style_bold_white)" \
      "$current_line" \
      "$(baish_agent_style_reset)"
  else
    printf '  %s%s%s %s%s%s\n' \
      "$(baish_agent_style_cyan)" \
      "$continuation_label" \
      "$(baish_agent_style_reset)" \
      "$(baish_agent_style_bold_white)" \
      "$current_line" \
      "$(baish_agent_style_reset)"
  fi
}

baish_agent_print_tool_round_item() {
  local tool_name="$1"
  local summary="$2"
  local icon padded_name

  icon="$(baish_agent_tool_icon "$tool_name")" || return 1
  printf -v padded_name '%-5s' "$tool_name"

  if [[ -n "$summary" ]]; then
    printf '  %s%s %s%s%s\n' \
      "$(baish_agent_style_cyan)" \
      "$icon $padded_name" \
      "$(baish_agent_style_bold_white)" \
      "$summary" \
      "$(baish_agent_style_reset)"
  else
    printf '  %s%s%s\n' \
      "$(baish_agent_style_cyan)" \
      "$icon $tool_name" \
      "$(baish_agent_style_reset)"
  fi
}

baish_agent_print_tool_round_result_summary() {
  local status="$1"
  local summary="$2"
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

  printf '   %s↳ %s%s %s%s\n' \
    "$(baish_agent_style_dim)" \
    "$color" \
    "$icon" \
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

  printf '  %s%s%s %s%s\n' \
    "$color" \
    "$icon" \
    "$(baish_agent_style_reset)" \
    "$text" \
    "$(baish_agent_style_reset)"
}

baish_agent_print_tool_round_result_detail() {
  local detail="$1"
  local line

  # Strip at most one trailing newline to avoid a phantom empty border line
  # from the here-string <<< adding an extra newline.
  if [[ -n "$detail" && "${detail: -1}" == $'\n' ]]; then
    detail="${detail%$'\n'}"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '     %s%s\n' \
      "$line" \
      "$(baish_agent_style_reset)"
  done <<<"$detail"
}

baish_agent_print_tool_round_detail() {
  local detail="$1"
  local first_line=1 line

  # Strip at most one trailing newline to avoid a phantom empty indented line
  # from the here-string <<< adding an extra newline.
  if [[ -n "$detail" && "${detail: -1}" == $'\n' ]]; then
    detail="${detail%$'\n'}"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( first_line == 1 )); then
      printf '   %s↳ %s%s\n' \
        "$(baish_agent_style_dim)" \
        "$line" \
        "$(baish_agent_style_reset)"
      first_line=0
    else
      printf '     %s%s\n' \
        "$line" \
        "$(baish_agent_style_reset)"
    fi
  done <<<"$detail"
}

baish_agent_print_assistant_response() {
  local assistant_text="$1"
  local line

  baish_agent_print_separator "💬" "Reply"

  # Strip at most one trailing newline to avoid a phantom empty line
  # from the here-string <<< adding an extra newline.
  if [[ -n "$assistant_text" && "${assistant_text: -1}" == $'\n' ]]; then
    assistant_text="${assistant_text%$'\n'}"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      printf '  %s%s%s\n' \
        "$(baish_agent_style_bold_white)" \
        "$line" \
        "$(baish_agent_style_reset)"
    else
      printf '\n'
    fi
  done <<<"$assistant_text"
}

# ─── Streaming availability check ────────────────────────────────────

