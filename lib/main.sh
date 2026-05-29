#!/usr/bin/env bash

# shellcheck disable=SC2034
BAISH_LIB_PATH="${BASH_SOURCE[0]}"
BAISH_LIB_DIR_PART="${BAISH_LIB_PATH%/*}"
if [[ "$BAISH_LIB_DIR_PART" == "$BAISH_LIB_PATH" ]]; then
  BAISH_LIB_DIR_PART='.'
fi
BAISH_REPO_ROOT="$(cd -- "$BAISH_LIB_DIR_PART/.." && pwd)"

# shellcheck source=deps.sh
source "$BAISH_REPO_ROOT/lib/deps.sh"
# shellcheck source=readline.sh
source "$BAISH_REPO_ROOT/lib/readline.sh"
# shellcheck source=slash.sh
source "$BAISH_REPO_ROOT/lib/slash.sh"
# shellcheck source=context.sh
source "$BAISH_REPO_ROOT/lib/context.sh"
# shellcheck source=agent.sh
source "$BAISH_REPO_ROOT/lib/agent.sh"
# shellcheck source=tools.sh
source "$BAISH_REPO_ROOT/lib/tools.sh"
# shellcheck source=log.sh
source "$BAISH_REPO_ROOT/lib/log.sh"
# shellcheck source=state.sh
source "$BAISH_REPO_ROOT/lib/state.sh"
# shellcheck source=providers/copilot.sh
source "$BAISH_REPO_ROOT/lib/providers/copilot.sh"
# shellcheck source=providers/mock.sh
source "$BAISH_REPO_ROOT/lib/providers/mock.sh"

baish_startup_use_color() {
  [[ -t 1 && "${TERM:-}" != "dumb" ]]
}

baish_startup_color() {
  local style="$1"

  case "$style" in
    bold) printf '\033[1m' ;;
    cyan) printf '\033[36m' ;;
    green) printf '\033[32m' ;;
    dim) printf '\033[2m' ;;
    reset) printf '\033[0m' ;;
  esac
}

baish_startup_print_header() {
  local bold cyan green dim reset

  if baish_startup_use_color; then
    bold="$(baish_startup_color bold)"
    cyan="$(baish_startup_color cyan)"
    green="$(baish_startup_color green)"
    dim="$(baish_startup_color dim)"
    reset="$(baish_startup_color reset)"
  fi

  printf '%b\n' "${bold}${cyan}BAISH${reset}"
  printf '%b\n' "${green}Bash Assistant for Interactive Shell workflows${reset}"
  printf '%b\n' "${dim}Slash commands:${reset}"
  printf '  %b/connect%b        connect and choose a model\n' "$cyan" "$reset"
  printf '  %b/new%b            start a fresh chat\n' "$cyan" "$reset"
  printf '  %b/model%b          pick a model interactively\n' "$cyan" "$reset"
  printf '  %b/skill:<name>%b    load a skill into this session\n' "$cyan" "$reset"
  printf '  %b/quit%b           exit BAISH\n' "$cyan" "$reset"
  printf '  %b/exit%b           alias for /quit\n' "$cyan" "$reset"
}

baish_main() {
  if [[ "${1-}" == "--help" || "${1-}" == "-h" ]]; then
    cat <<'EOF'
Usage: baish

BAISH is a readline-style terminal AI coding agent.
Use /quit to exit.
EOF
    return 0
  fi

  local active_provider active_model startup_metadata

  baish_check_runtime_dependencies || return 1
  baish_state_init || return 1
  baish_log_init || return 1

  active_provider="$(baish_config_active_provider)" || return 1
  active_model="$(baish_config_active_model)" || return 1

  BAISH_ACTIVE_PROVIDER="$active_provider"
  BAISH_ACTIVE_MODEL="$active_model"
  BAISH_LAUNCH_CWD="$PWD"

  baish_session_reset

  startup_metadata="$(jq -cn --arg provider "$active_provider" --arg model "$active_model" --arg cwd "$PWD" '{provider: $provider, model: (if $model == "" then null else $model end), cwd: $cwd}')" || return 1
  baish_log_event 'startup' "$startup_metadata" || return 1

  baish_startup_print_header
  baish_readline_loop
}
