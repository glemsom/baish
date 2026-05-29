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
  if ! [[ -o emacs || -o vi ]]; then
    set -o emacs || return 1
  fi

  bind -x '"\C-i":baish_readline_handle_tab'
}

baish_readline_loop() {
  local line read_status
  local interactive=0

  baish_session_init

  if [[ -t 0 && -t 1 ]]; then
    interactive=1
    baish_readline_install_bindings || return 1
  fi

  trap 'BAISH_READLINE_INTERRUPTED=1' INT

  while true; do
    BAISH_READLINE_INTERRUPTED=0
    line=''

    if (( interactive == 1 )); then
      if read -e -r -p 'baish> ' line; then
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
        if (( interactive == 1 )); then
          printf '\n'
        fi
        continue
      fi

      if (( interactive == 1 )); then
        printf '\n'
      fi
      break
    fi

    if ! baish_process_input_line "$line"; then
      if [[ "${BAISH_READLINE_INTERRUPTED:-0}" == "1" && $interactive -eq 1 ]]; then
        printf '\n'
      fi
      continue
    fi

    if [[ "${BAISH_SESSION_EXIT_REQUESTED:-0}" == "1" ]]; then
      break
    fi
  done

  trap - INT
}
