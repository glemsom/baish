#!/usr/bin/env bash

baish_prompt_secret() {
  local prompt="$1"
  local stty_state secret status

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'BAISH cannot prompt for hidden input without an interactive terminal.\n' >&2
    return 1
  fi

  printf '%s' "$prompt" >&2
  stty_state="$(stty -g 2>/dev/null)" || {
    printf '\n' >&2
    return 1
  }

  if ! stty -echo 2>/dev/null; then
    printf '\n' >&2
    return 1
  fi

  status=0
  if ! IFS= read -r secret; then
    status=$?
  fi

  stty "$stty_state" 2>/dev/null || true
  printf '\n' >&2

  if (( status != 0 )); then
    return "$status"
  fi

  printf '%s\n' "$secret"
}
