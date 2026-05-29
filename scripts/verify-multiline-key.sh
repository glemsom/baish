#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "${SCRIPT_PATH%/*}" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-observe}"

print_sequence() {
  local sequence="$1"
  local hex=''
  local index byte

  for (( index = 0; index < ${#sequence}; index++ )); do
    printf -v byte '%02X' "'${sequence:index:1}"
    hex+="${hex:+ }$byte"
  done

  printf 'bytes: %s\n' "$hex"
  printf 'bash : %q\n' "$sequence"
}

observe_keys() {
  local first rest sequence

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'observe mode requires a terminal.\n' >&2
    return 1
  fi

  printf '\e[>1u'
  trap 'printf "\e[<u\n"' EXIT

  cat <<'EOF'
Observe mode
------------
- Kitty keyboard protocol is enabled for this session.
- Press keys to inspect their escape sequences.
- Press Ctrl-C to exit.
- Try Enter, Shift+Enter, and Alt+Enter in Ghostty and Kitty.
EOF

  while true; do
    IFS= read -rsn1 first
    sequence="$first"

    while IFS= read -rsn1 -t 0.05 rest; do
      sequence+="$rest"
    done

    print_sequence "$sequence"
    printf '\n'
  done
}

poc_readline() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'poc mode requires a terminal.\n' >&2
    return 1
  fi

  # shellcheck source=../lib/readline.sh
  source "$REPO_ROOT/lib/readline.sh"

  baish_slash_completion_candidates() {
    return 0
  }

  baish_readline_enable_keyboard_protocol
  trap 'baish_readline_disable_keyboard_protocol; printf "\n"' EXIT
  baish_readline_install_bindings

  cat <<'EOF'
Readline PoC mode
-----------------
- Enter should submit the current draft.
- The dedicated newline-insert key should continue the draft onto the next physical line.
- Submitted drafts are shown with shell escaping via printf %q.
- Press Ctrl-D to exit.
EOF

  while true; do
    local line=''

    if ! read -e -r -p 'demo> ' line; then
      break
    fi

    printf 'submitted: %q\n' "$line"
  done
}

case "$MODE" in
  observe)
    observe_keys
    ;;
  poc)
    poc_readline
    ;;
  *)
    printf 'Usage: %s [observe|poc]\n' "$0" >&2
    exit 1
    ;;
esac
