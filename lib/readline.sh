#!/usr/bin/env bash

baish_readline_locate_token() {
  local line="$1"
  local point="$2"
  local start end char

  start="$point"
  end="$point"

  while (( start > 0 )); do
    char="${line:start-1:1}"
    if [[ "$char" =~ [[:space:]] ]]; then
      break
    fi
    ((start--))
  done

  while (( end < ${#line} )); do
    char="${line:end:1}"
    if [[ "$char" =~ [[:space:]] ]]; then
      break
    fi
    ((end++))
  done

  BAISH_READLINE_TOKEN_START="$start"
  BAISH_READLINE_TOKEN_END="$end"
  BAISH_READLINE_CURRENT_TOKEN="${line:start:end-start}"
}

baish_readline_common_prefix() {
  local prefix="$1"
  local candidate index

  shift

  for candidate in "$@"; do
    while [[ "$candidate" != "$prefix"* ]]; do
      if [[ -z "$prefix" ]]; then
        break
      fi
      prefix="${prefix%?}"
    done
  done

  printf '%s\n' "$prefix"
}

baish_readline_replace_token() {
  local replacement="$1"
  local append_space="${2:-0}"
  local prefix suffix

  prefix="${READLINE_LINE:0:BAISH_READLINE_TOKEN_START}"
  suffix="${READLINE_LINE:BAISH_READLINE_TOKEN_END}"

  if [[ "$append_space" == "1" ]]; then
    replacement+=" "
  fi

  READLINE_LINE="${prefix}${replacement}${suffix}"
  READLINE_POINT=$(( BAISH_READLINE_TOKEN_START + ${#replacement} ))
}

baish_readline_insert_text() {
  local text="$1"
  local line point prefix suffix

  line="${READLINE_LINE:-}"
  point="${READLINE_POINT:-0}"
  prefix="${line:0:point}"
  suffix="${line:point}"

  READLINE_LINE="${prefix}${text}${suffix}"
  READLINE_POINT=$(( point + ${#text} ))
  BAISH_READLINE_COMPLETION_STATE=''
  BAISH_READLINE_COMPLETION_INDEX=0
}

baish_readline_insert_newline() {
  baish_readline_insert_text $'\n'
}

baish_readline_handle_newline_insert() {
  baish_readline_insert_newline
}

baish_readline_continue_marker() {
  printf '%b\n' '\342\201\243\342\201\240\342\200\213\342\201\243'
}

baish_readline_continuation_prompt() {
  printf '%s\n' '       '
}

baish_readline_line_requests_continuation() {
  local line="$1"
  local marker

  marker="$(baish_readline_continue_marker)"
  [[ "$line" == *"$marker" ]]
}

baish_readline_strip_continuation_marker() {
  local line="$1"
  local marker

  marker="$(baish_readline_continue_marker)"
  BAISH_READLINE_STRIPPED_LINE="${line%$marker}"
}

baish_readline_enable_keyboard_protocol() {
  if [[ -t 1 ]]; then
    printf '\e[>1u'
  fi
}

baish_readline_disable_keyboard_protocol() {
  if [[ -t 1 ]]; then
    printf '\e[<u'
  fi
}

baish_readline_footer_line_count() {
  printf '2\n'
}

baish_readline_draw_idle_screen() {
  local prompt_line="${1:-}"
  local cursor_up

  cursor_up=$(( $(baish_readline_footer_line_count) + 1 ))

  printf '\n'
  baish_footer_render_lines
  printf '\033[%sA\r' "$cursor_up"
  if [[ -n "$prompt_line" ]]; then
    printf '%s' "$prompt_line"
  fi

  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
}

baish_readline_clear_idle_screen_from_prompt_line() {
  local footer_lines remaining

  footer_lines="$(baish_readline_footer_line_count)"
  if ! [[ "$footer_lines" =~ ^[0-9]+$ ]] || (( footer_lines < 0 )); then
    footer_lines=0
  fi

  printf '\r\033[2K'
  remaining="$footer_lines"
  while (( remaining > 0 )); do
    printf '\033[B\r\033[2K'
    remaining=$(( remaining - 1 ))
  done

  if (( footer_lines > 0 )); then
    printf '\033[%sA\r' "$footer_lines"
  fi

  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}

baish_readline_leave_idle_screen() {
  local footer_lines remaining

  if [[ "${BAISH_READLINE_IDLE_SCREEN_VISIBLE:-0}" != "1" ]]; then
    return 0
  fi

  footer_lines="$(baish_readline_footer_line_count)"
  if ! [[ "$footer_lines" =~ ^[0-9]+$ ]] || (( footer_lines <= 0 )); then
    BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
    return 0
  fi

  printf '\r\033[2K'
  remaining=$(( footer_lines - 1 ))
  while (( remaining > 0 )); do
    printf '\033[B\r\033[2K'
    remaining=$(( remaining - 1 ))
  done

  if (( footer_lines > 1 )); then
    printf '\033[%sA\r' "$(( footer_lines - 1 ))"
  fi

  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}

baish_readline_redraw_idle_screen() {
  local prompt_line="${1:-}"

  if [[ "${BAISH_READLINE_IDLE_SCREEN_VISIBLE:-0}" == "1" ]]; then
    baish_readline_clear_idle_screen_from_prompt_line
  fi

  baish_readline_draw_idle_screen "$prompt_line"
}

baish_readline_cleanup_idle_screen() {
  if [[ "${BAISH_READLINE_IDLE_SCREEN_VISIBLE:-0}" == "1" ]]; then
    baish_readline_clear_idle_screen_from_prompt_line
  fi

  printf '\n'
}

baish_readline_handle_winch() {
  if [[ "${BAISH_READLINE_INTERACTIVE:-0}" != "1" ]]; then
    return 0
  fi

  if [[ "${BAISH_READLINE_IDLE_SCREEN_VISIBLE:-0}" != "1" ]]; then
    return 0
  fi

  baish_readline_redraw_idle_screen "${BAISH_READLINE_PROMPT:-❯ }"
}

baish_readline_handle_tab() {
  local line point common_prefix state_key next_index append_space=0
  local -a candidates=()

  line="${READLINE_LINE:-}"
  point="${READLINE_POINT:-0}"

  while IFS= read -r candidate; do
    if [[ -n "$candidate" ]]; then
      candidates+=("$candidate")
    fi
  done < <(baish_slash_completion_candidates "$line" "$point")

  if (( ${#candidates[@]} == 0 )); then
    return 0
  fi

  baish_readline_locate_token "$line" "$point"

  if (( ${#candidates[@]} == 1 )); then
    if [[ "${candidates[0]}" != '/skill:' ]]; then
      append_space=1
    fi
    baish_readline_replace_token "${candidates[0]}" "$append_space"
    BAISH_READLINE_COMPLETION_STATE=''
    BAISH_READLINE_COMPLETION_INDEX=0
    return 0
  fi

  common_prefix="$(baish_readline_common_prefix "${candidates[0]}" "${candidates[@]:1}")"
  if [[ ${#common_prefix} -gt ${#BAISH_READLINE_CURRENT_TOKEN} ]]; then
    baish_readline_replace_token "$common_prefix" 0
    BAISH_READLINE_COMPLETION_STATE=''
    BAISH_READLINE_COMPLETION_INDEX=0
    return 0
  fi

  state_key="${line}|${point}|${candidates[*]}"
  if [[ "${BAISH_READLINE_COMPLETION_STATE:-}" == "$state_key" ]]; then
    next_index=$(( (${BAISH_READLINE_COMPLETION_INDEX:-0} + 1) % ${#candidates[@]} ))
  else
    next_index=0
  fi

  baish_readline_replace_token "${candidates[$next_index]}" 0
  BAISH_READLINE_COMPLETION_STATE="$state_key"
  BAISH_READLINE_COMPLETION_INDEX="$next_index"
}

baish_readline_install_bindings() {
  local continue_marker

  if ! [[ -o emacs || -o vi ]]; then
    set -o emacs || return 1
  fi

  continue_marker="$(baish_readline_continue_marker)"

  bind -x '"\C-i":baish_readline_handle_tab'
  bind '"\e[A":previous-history'
  bind '"\e[B":next-history'
  bind '"\e[C":forward-char'
  bind '"\e[D":backward-char'
  bind '"\eOA":previous-history'
  bind '"\eOB":next-history'
  bind '"\eOC":forward-char'
  bind '"\eOD":backward-char'
  bind '"\e[1;1A":previous-history'
  bind '"\e[1;1B":next-history'
  bind '"\e[1;1C":forward-char'
  bind '"\e[1;1D":backward-char'
  bind '"\e[1;129A":previous-history'
  bind '"\e[1;129B":next-history'
  bind '"\e[1;129C":forward-char'
  bind '"\e[1;129D":backward-char'
  bind '"\234":forward-char'
  bind '"\235":backward-char'
  bind '"\e[13;2u":"'"$continue_marker"'\C-m"'
  bind '"\e[13;130u":"'"$continue_marker"'\C-m"'
  bind '"\e[13;131u":"'"$continue_marker"'\C-m"'
  bind '"\e[27;2;13~":"'"$continue_marker"'\C-m"'
  bind '"\e\C-m":"'"$continue_marker"'\C-m"'
  bind '"\e[99;5u":"\C-c"'
  bind '"\e[99;133u":"\C-c"'
  bind '"\e[100;5u":"\C-d"'
  bind '"\e[100;133u":"\C-d"'
}

baish_readline_loop() {
  local line read_status prompt draft
  local interactive=0

  baish_session_init
  prompt='❯ '
  draft=''
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
  BAISH_READLINE_INTERACTIVE=0
  BAISH_READLINE_PROMPT="$prompt"

  if [[ -t 0 && -t 1 ]]; then
    interactive=1
    BAISH_READLINE_INTERACTIVE=1
    baish_readline_enable_keyboard_protocol
    baish_readline_install_bindings || {
      baish_readline_disable_keyboard_protocol
      BAISH_READLINE_INTERACTIVE=0
      return 1
    }
    baish_readline_draw_idle_screen "$prompt"
  fi

  trap 'BAISH_READLINE_INTERRUPTED=1' INT
  trap 'baish_readline_handle_winch' WINCH

  while true; do
    BAISH_READLINE_INTERRUPTED=0
    line=''

    if (( interactive == 1 )); then
      if read -e -r line; then
        read_status=0
      else
        read_status=$?
      fi
    else
      if read -r line; then
        read_status=0
      else
        read_status=$?
      fi
    fi

    if (( read_status != 0 )); then
      if [[ "${BAISH_READLINE_INTERRUPTED:-0}" == "1" || $read_status -eq 130 ]]; then
        draft=''
        prompt='❯ '
        BAISH_READLINE_PROMPT="$prompt"
        if (( interactive == 1 )); then
          baish_readline_redraw_idle_screen "$prompt"
        fi
        continue
      fi

      if (( interactive == 1 )); then
        baish_readline_cleanup_idle_screen
      fi
      break
    fi

    if (( interactive == 1 )); then
      baish_readline_leave_idle_screen
    fi

    if (( interactive == 1 )) && baish_readline_line_requests_continuation "$line"; then
      baish_readline_strip_continuation_marker "$line"
      draft+="$BAISH_READLINE_STRIPPED_LINE"$'\n'
      prompt="$(baish_readline_continuation_prompt)"
      BAISH_READLINE_PROMPT="$prompt"
      baish_readline_draw_idle_screen "$prompt"
      continue
    fi

    if [[ -n "$draft" ]]; then
      line="${draft}${line}"
      draft=''
      prompt='❯ '
      BAISH_READLINE_PROMPT="$prompt"
    fi

    if ! baish_process_input_line "$line"; then
      prompt='❯ '
      BAISH_READLINE_PROMPT="$prompt"
      if (( interactive == 1 )); then
        baish_readline_draw_idle_screen "$prompt"
      fi
      continue
    fi

    prompt='❯ '
    BAISH_READLINE_PROMPT="$prompt"

    if [[ "${BAISH_SESSION_EXIT_REQUESTED:-0}" == "1" ]]; then
      if (( interactive == 1 )); then
        printf '\n'
      fi
      break
    fi

    if (( interactive == 1 )); then
      baish_readline_draw_idle_screen "$prompt"
    fi
  done

  trap - INT
  trap - WINCH

  if (( interactive == 1 )); then
    baish_readline_disable_keyboard_protocol
  fi

  BAISH_READLINE_INTERACTIVE=0
}
