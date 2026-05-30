#!/usr/bin/env bats

load test_helper.bash

baish_agent_run_user_message() {
  BAISH_TEST_AGENT_CALLS=$(( ${BAISH_TEST_AGENT_CALLS:-0} + 1 ))
  BAISH_TEST_AGENT_LAST_MESSAGE="$1"
}

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"

  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  cd "$TEST_PROJECT"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/providers.sh"
  source "$REPO_ROOT/lib/slash.sh"
  source "$REPO_ROOT/lib/readline.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"

  unset BAISH_MODEL
  unset BAISH_PROVIDER
  unset BAISH_ACTIVE_PROVIDER
  unset BAISH_ACTIVE_MODEL
  unset BAISH_TEST_AGENT_CALLS
  unset BAISH_TEST_AGENT_LAST_MESSAGE

  baish_state_init
  baish_session_reset
}

@test "slash parser handles a single slash command" {
  baish_slash_parse_line '/connect'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'connect' ]
  [ -z "${BAISH_SLASH_ARGS[0]}" ]
  [ -z "$BAISH_SLASH_REMAINING_TEXT" ]
}

@test "slash parser handles /provider" {
  baish_slash_parse_line '/provider'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'provider' ]
  [ -z "$BAISH_SLASH_REMAINING_TEXT" ]
}

@test "slash parser handles multiple slash commands before chat text" {
  baish_slash_parse_line '/skill:tdd /skill:pirate Fix the auth bug'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 2 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'skill' ]
  [ "${BAISH_SLASH_ARGS[0]}" = 'tdd' ]
  [ "${BAISH_SLASH_COMMANDS[1]}" = 'skill' ]
  [ "${BAISH_SLASH_ARGS[1]}" = 'pirate' ]
  [ "$BAISH_SLASH_REMAINING_TEXT" = 'Fix the auth bug' ]
}

@test "slash parser trims newline separators before multiline chat text" {
  baish_slash_parse_line $'/skill:tdd\n\nInvestigate auth'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'skill' ]
  [ "${BAISH_SLASH_ARGS[0]}" = 'tdd' ]
  [ "$BAISH_SLASH_REMAINING_TEXT" = 'Investigate auth' ]
}

@test "slash-looking text after chat begins remains chat text" {
  baish_slash_parse_line '/skill:tdd Fix /skill:pirate later'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'skill' ]
  [ "$BAISH_SLASH_REMAINING_TEXT" = 'Fix /skill:pirate later' ]
}

@test "slash-looking text after multiline chat begins remains chat text" {
  baish_slash_parse_line $'/skill:tdd Fix this first\n/skill:pirate later'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'skill' ]
  [ "$BAISH_SLASH_REMAINING_TEXT" = $'Fix this first\n/skill:pirate later' ]
}

@test "colon arguments only are enforced" {
  run bash -lc '
    source "$1/lib/state.sh"
    source "$1/lib/slash.sh"
    HOME="$2"
    baish_state_init
    if baish_slash_parse_line "/skill tdd"; then
      exit 99
    fi
    printf "%s\n" "$BAISH_SLASH_PARSE_ERROR"
  ' bash "$REPO_ROOT" "$TEST_HOME"

  [ "$status" -eq 0 ]
  [ "$output" = 'Unknown slash command: /skill' ]
}

@test "/provider:name reports a helpful error" {
  run bash -lc '
    source "$1/lib/state.sh"
    source "$1/lib/slash.sh"
    HOME="$2"
    baish_state_init
    if baish_slash_parse_line "/provider:kilo"; then
      exit 99
    fi
    printf "%s\n" "$BAISH_SLASH_PARSE_ERROR"
  ' bash "$REPO_ROOT" "$TEST_HOME"

  [ "$status" -eq 0 ]
  [ "$output" = 'BAISH does not support /provider:<name>. Use /provider to open the provider picker.' ]
}

@test "/exit aliases /quit" {
  baish_slash_parse_line '/exit'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'quit' ]
}

@test "/new resets only the conversation messages" {
  local output_file output status

  mkdir -p "$TEST_PROJECT/.baish/skills/tdd"
  printf 'project tdd\n' >"$TEST_PROJECT/.baish/skills/tdd/SKILL.md"

  baish_skill_load 'tdd'
  BAISH_SESSION_MESSAGES+=('{"role":"user","content":"first"}')
  BAISH_SESSION_MESSAGES+=('{"role":"assistant","content":"second"}')

  output_file="$BATS_TEST_TMPDIR/new-output"
  baish_slash_execute_command 'new' >"$output_file"
  status=$?
  output="$(<"$output_file")"

  [ "$status" -eq 0 ]
  [ "$output" = 'Started new chat.' ]
  [ "${#BAISH_SESSION_MESSAGES[@]}" -eq 0 ]
  [ "${#BAISH_SESSION_SKILL_NAMES[@]}" -eq 1 ]
  [ "${BAISH_SESSION_SKILL_NAMES[0]}" = 'tdd' ]
}

@test "skill loading prefers project-local skills, falls back to user skills, and stays idempotent" {
  mkdir -p "$TEST_PROJECT/.baish/skills/tdd" "$TEST_HOME/.baish/skills/tdd" "$TEST_HOME/.baish/skills/pirate"
  printf 'project tdd\n' >"$TEST_PROJECT/.baish/skills/tdd/SKILL.md"
  printf 'user tdd\n' >"$TEST_HOME/.baish/skills/tdd/SKILL.md"
  printf 'user pirate\n' >"$TEST_HOME/.baish/skills/pirate/SKILL.md"

  baish_skill_load 'tdd'
  baish_skill_load 'pirate'
  baish_skill_load 'tdd'

  [ "${#BAISH_SESSION_SKILL_NAMES[@]}" -eq 2 ]
  [ "${BAISH_SESSION_SKILL_NAMES[0]}" = 'tdd' ]
  [ "${BAISH_SESSION_SKILL_NAMES[1]}" = 'pirate' ]
  [ "${BAISH_SESSION_SKILL_PATHS[0]}" = "$TEST_PROJECT/.baish/skills/tdd/SKILL.md" ]
  [ "${BAISH_SESSION_SKILL_PATHS[1]}" = "$TEST_HOME/.baish/skills/pirate/SKILL.md" ]
  [ "${BAISH_SESSION_SKILL_CONTENTS[0]}" = 'project tdd' ]
  [ "${BAISH_SESSION_SKILL_CONTENTS[1]}" = 'user pirate' ]
}

@test "slash completion supports commands, skills, and multiple slash commands on one line" {
  mkdir -p "$TEST_PROJECT/.baish/skills/tdd" "$TEST_HOME/.baish/skills/pirate"
  printf 'project tdd\n' >"$TEST_PROJECT/.baish/skills/tdd/SKILL.md"
  printf 'user pirate\n' >"$TEST_HOME/.baish/skills/pirate/SKILL.md"

  run bash -lc '
    source "$1/lib/state.sh"
    source "$1/lib/slash.sh"
    HOME="$2"
    cd "$3"
    baish_state_init
    baish_session_reset
    baish_slash_completion_candidates "/p" 2
    printf -- "--\n"
    baish_slash_completion_candidates "/n" 2
    printf -- "--\n"
    baish_slash_completion_candidates "/sk" 3
    printf -- "--\n"
    baish_slash_completion_candidates "/skill:t" 8
    printf -- "--\n"
    baish_slash_completion_candidates "/skill:tdd /sk" 14
  ' bash "$REPO_ROOT" "$TEST_HOME" "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  [[ "$output" == $'/provider\n--\n/new\n--\n/skill:\n--\n/skill:tdd\n--\n/skill:'* ]]
}

@test "provider picker entries show only selectable providers sorted by label with an active marker" {
  BAISH_PROVIDER_DISCOVERY_DONE=1
  BAISH_PROVIDER_IDS=(gamma alpha hidden)
  declare -gA BAISH_PROVIDER_METADATA_JSON=()
  BAISH_PROVIDER_METADATA_JSON[gamma]='{"id":"gamma","label":"Zulu","desc":"Gamma desc","selectable":true}'
  BAISH_PROVIDER_METADATA_JSON[alpha]='{"id":"alpha","label":"alpha","desc":"Alpha desc","selectable":true}'
  BAISH_PROVIDER_METADATA_JSON[hidden]='{"id":"hidden","label":"Hidden","desc":"Hidden desc","selectable":false}'
  BAISH_PROCESS_SELECTED_PROVIDER='gamma'

  run baish_provider_selection_entries 'gamma'

  [ "$status" -eq 0 ]
  [ "$output" = $'alpha — Alpha desc\talpha\nZulu — Gamma desc (active)\tgamma' ]
}

@test "readline insert text mutates READLINE_LINE and READLINE_POINT" {
  READLINE_LINE='alphaomega'
  READLINE_POINT=5

  baish_readline_insert_text ' '

  [ "$READLINE_LINE" = 'alpha omega' ]
  [ "$READLINE_POINT" -eq 6 ]
}

@test "readline insert newline preserves prefix and suffix" {
  READLINE_LINE='alphabeta'
  READLINE_POINT=5

  baish_readline_insert_newline

  [ "$READLINE_LINE" = $'alpha\nbeta' ]
  [ "$READLINE_POINT" -eq 6 ]
}

@test "readline continuation marker is detected and stripped" {
  local marker line

  marker="$(baish_readline_continue_marker)"
  line="alpha${marker}"

  baish_readline_line_requests_continuation "$line"
  baish_readline_strip_continuation_marker "$line"

  [ "$BAISH_READLINE_STRIPPED_LINE" = 'alpha' ]
}

@test "readline continuation prompt is blank-aligned" {
  [ "$(baish_readline_continuation_prompt)" = '       ' ]
}

@test "readline draw idle screen renders footer below the input line" {
  local output_file output

  baish_footer_render_lines() {
    printf 'divider\nstatus\n'
  }

  output_file="$BATS_TEST_TMPDIR/idle-draw"
  baish_readline_draw_idle_screen '❯ ' >"$output_file"
  output="$(<"$output_file")"

  [ "$BAISH_READLINE_IDLE_SCREEN_VISIBLE" = '1' ]
  [ "$output" = $'\ndivider\nstatus\n\e[3A\r❯ ' ]
}

@test "readline draw idle screen keeps a usable footer block when footer formatting fails" {
  local output_file output

  source "$REPO_ROOT/lib/footer.sh"

  baish_footer_divider_line() {
    return 1
  }

  baish_footer_format_status_line() {
    return 1
  }

  COLUMNS=12
  output_file="$BATS_TEST_TMPDIR/idle-draw-fallback"
  baish_readline_draw_idle_screen '❯ ' >"$output_file"
  output="$(<"$output_file")"

  [ "$BAISH_READLINE_IDLE_SCREEN_VISIBLE" = '1' ]
  [ "$output" = $'\n────────────\n? · unknown…\n\e[3A\r❯ ' ]
}

@test "readline leaves the idle screen by clearing footer lines" {
  local output_file output

  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1

  output_file="$BATS_TEST_TMPDIR/idle-leave"
  baish_readline_leave_idle_screen >"$output_file"
  output="$(<"$output_file")"

  [ "$BAISH_READLINE_IDLE_SCREEN_VISIBLE" = '0' ]
  [ "$output" = $'\r\e[2K\e[B\r\e[2K\e[1A\r' ]
}

@test "readline redraw clears the existing idle block before drawing again" {
  local output_file output

  baish_footer_render_lines() {
    printf 'divider\nstatus\n'
  }
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1

  output_file="$BATS_TEST_TMPDIR/idle-redraw"
  baish_readline_redraw_idle_screen '❯ ' >"$output_file"
  output="$(<"$output_file")"

  [ "$BAISH_READLINE_IDLE_SCREEN_VISIBLE" = '1' ]
  [ "$output" = $'\r\e[2K\e[B\r\e[2K\e[B\r\e[2K\e[2A\r\ndivider\nstatus\n\e[3A\r❯ ' ]
}

@test "readline WINCH handler redraws the visible idle screen with the current prompt" {
  local output_file output

  baish_readline_redraw_idle_screen() {
    printf 'REDRAW<%s>\n' "$1"
  }

  BAISH_READLINE_INTERACTIVE=1
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
  BAISH_READLINE_PROMPT='       '

  output_file="$BATS_TEST_TMPDIR/idle-winch"
  baish_readline_handle_winch >"$output_file"
  output="$(<"$output_file")"

  [ "$output" = 'REDRAW<       >' ]
}

@test "readline loop uses the idle screen lifecycle around interactive reads" {
  local loop_script

  loop_script="$BATS_TEST_TMPDIR/readline-loop-lifecycle.sh"
  cat >"$loop_script" <<'EOF'
#!/usr/bin/env bash
source "__REPO_ROOT__/lib/readline.sh"

baish_session_init() { :; }
baish_readline_enable_keyboard_protocol() { :; }
baish_readline_disable_keyboard_protocol() { :; }
baish_readline_install_bindings() { :; }
baish_readline_draw_idle_screen() {
  printf 'DRAW<%s>\n' "$1"
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
}
baish_readline_leave_idle_screen() {
  printf 'LEAVE\n'
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}
baish_readline_clear_idle_screen_from_prompt_line() {
  printf 'CLEAR\n'
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}
baish_process_input_line() {
  printf 'PROCESS<%s>\n' "$1"
}

BAISH_TEST_READ_CALLS=0
read() {
  local target="${*: -1}"

  BAISH_TEST_READ_CALLS=$(( BAISH_TEST_READ_CALLS + 1 ))
  if (( BAISH_TEST_READ_CALLS == 1 )); then
    printf -v "$target" '%s' 'hello'
    return 0
  fi

  return 1
}

baish_readline_loop
EOF
  sed -i "s|__REPO_ROOT__|$REPO_ROOT|g" "$loop_script"
  chmod +x "$loop_script"

  run bash -lc 'script -qec "$1" /dev/null | tr -d "\r"' bash "$loop_script"

  [ "$status" -eq 0 ]
  [ "$output" = $'DRAW<❯ >\nLEAVE\nPROCESS<hello>\nDRAW<❯ >\nCLEAR' ]
}

@test "readline loop redraws the idle screen after an interrupt" {
  local loop_script

  loop_script="$BATS_TEST_TMPDIR/readline-loop-interrupt.sh"
  cat >"$loop_script" <<'EOF'
#!/usr/bin/env bash
source "__REPO_ROOT__/lib/readline.sh"

baish_session_init() { :; }
baish_readline_enable_keyboard_protocol() { :; }
baish_readline_disable_keyboard_protocol() { :; }
baish_readline_install_bindings() { :; }
baish_readline_draw_idle_screen() {
  printf 'DRAW<%s>\n' "$1"
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
}
baish_readline_redraw_idle_screen() {
  printf 'REDRAW<%s>\n' "$1"
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
}
baish_readline_clear_idle_screen_from_prompt_line() {
  printf 'CLEAR\n'
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}
baish_process_input_line() {
  printf 'PROCESS<%s>\n' "$1"
}

BAISH_TEST_READ_CALLS=0
read() {
  local target="${*: -1}"

  BAISH_TEST_READ_CALLS=$(( BAISH_TEST_READ_CALLS + 1 ))
  if (( BAISH_TEST_READ_CALLS == 1 )); then
    printf -v "$target" '%s' ''
    BAISH_READLINE_INTERRUPTED=1
    return 130
  fi

  return 1
}

baish_readline_loop
EOF
  sed -i "s|__REPO_ROOT__|$REPO_ROOT|g" "$loop_script"
  chmod +x "$loop_script"

  run bash -lc 'script -qec "$1" /dev/null | tr -d "\r"' bash "$loop_script"

  [ "$status" -eq 0 ]
  [ "$output" = $'DRAW<❯ >\nREDRAW<❯ >\nCLEAR' ]
}

@test "readline loop redraws the idle screen after SIGWINCH" {
  local loop_script

  loop_script="$BATS_TEST_TMPDIR/readline-loop-winch.sh"
  cat >"$loop_script" <<'EOF'
#!/usr/bin/env bash
source "__REPO_ROOT__/lib/readline.sh"

baish_session_init() { :; }
baish_readline_enable_keyboard_protocol() { :; }
baish_readline_disable_keyboard_protocol() { :; }
baish_readline_install_bindings() { :; }
baish_readline_draw_idle_screen() {
  printf 'DRAW<%s>\n' "$1"
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
}
baish_readline_redraw_idle_screen() {
  printf 'REDRAW<%s>\n' "$1"
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=1
}
baish_readline_leave_idle_screen() {
  printf 'LEAVE\n'
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}
baish_readline_clear_idle_screen_from_prompt_line() {
  printf 'CLEAR\n'
  BAISH_READLINE_IDLE_SCREEN_VISIBLE=0
}
baish_process_input_line() {
  printf 'PROCESS<%s>\n' "$1"
}

BAISH_TEST_READ_CALLS=0
read() {
  local target="${*: -1}"

  BAISH_TEST_READ_CALLS=$(( BAISH_TEST_READ_CALLS + 1 ))
  if (( BAISH_TEST_READ_CALLS == 1 )); then
    COLUMNS=91
    kill -WINCH $$
    printf -v "$target" '%s' 'hello'
    return 0
  fi

  return 1
}

baish_readline_loop
EOF
  sed -i "s|__REPO_ROOT__|$REPO_ROOT|g" "$loop_script"
  chmod +x "$loop_script"

  run bash -lc 'script -qec "$1" /dev/null | tr -d "\r"' bash "$loop_script"

  [ "$status" -eq 0 ]
  [ "$output" = $'DRAW<❯ >\nREDRAW<❯ >\nLEAVE\nPROCESS<hello>\nDRAW<❯ >\nCLEAR' ]
}

@test "readline redraw picks up provider and model changes from current process state" {
  local loop_script

  loop_script="$BATS_TEST_TMPDIR/readline-loop-footer-refresh.sh"
  cat >"$loop_script" <<'EOF'
#!/usr/bin/env bash
source "__REPO_ROOT__/lib/state.sh"
source "__REPO_ROOT__/lib/footer.sh"
source "__REPO_ROOT__/lib/readline.sh"

baish_session_init() { :; }
baish_readline_enable_keyboard_protocol() { :; }
baish_readline_disable_keyboard_protocol() { :; }
baish_readline_install_bindings() { :; }
baish_provider_metadata_json() {
  case "$1" in
    old)
      printf '{"id":"old","label":"Old Provider"}\n'
      ;;
    demo)
      printf '{"id":"demo","label":"Demo Provider"}\n'
      ;;
    *)
      return 1
      ;;
  esac
}
baish_process_input_line() {
  BAISH_PROCESS_SELECTED_PROVIDER='demo'
  BAISH_PROCESS_SELECTED_MODEL='model-b'
}

BAISH_LAUNCH_CWD='/tmp/project'
BAISH_PROCESS_SELECTED_PROVIDER='old'
BAISH_PROCESS_SELECTED_MODEL='old-model'
BAISH_ACTIVE_PROVIDER='stale'
BAISH_ACTIVE_MODEL='stale-model'
COLUMNS=80

BAISH_TEST_READ_CALLS=0
read() {
  local target="${*: -1}"

  BAISH_TEST_READ_CALLS=$(( BAISH_TEST_READ_CALLS + 1 ))
  if (( BAISH_TEST_READ_CALLS == 1 )); then
    printf -v "$target" '%s' '/model'
    return 0
  fi

  return 1
}

baish_readline_loop
EOF
  sed -i "s|__REPO_ROOT__|$REPO_ROOT|g" "$loop_script"
  chmod +x "$loop_script"

  run bash -lc 'script -qec "$1" /dev/null | tr -d "\r"' bash "$loop_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *'/tmp/project · Old Provider · old-model'* ]]
  [[ "$output" == *'/tmp/project · Demo Provider · model-b'* ]]
}

@test "readline bindings install without line editing warnings" {
  run bash -lc '
    source "$1/lib/readline.sh"
    baish_readline_install_bindings
  ' bash "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "readline binds arrow key sequences for cursor and history movement" {
  run bash -lc '
    source "$1/lib/readline.sh"
    baish_readline_install_bindings
    bind -P
  ' bash "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"\M-[1;1A"'* ]]
  [[ "$output" == *'"\M-[1;1B"'* ]]
  [[ "$output" == *'"\M-[1;1C"'* ]]
  [[ "$output" == *'"\M-[1;1D"'* ]]
  [[ "$output" == *'"\M-[1;129A"'* ]]
  [[ "$output" == *'"\M-[1;129B"'* ]]
  [[ "$output" == *'"\M-[1;129C"'* ]]
  [[ "$output" == *'"\M-[1;129D"'* ]]
  [[ "$output" == *'"\M-\C-\\"'* ]]
  [[ "$output" == *'"\M-\C-]"'* ]]
}

@test "readline binds kitty ctrl-c and ctrl-d sequences back to control chars" {
  run bash -lc '
    source "$1/lib/readline.sh"
    baish_readline_install_bindings
    bind -s
  ' bash "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"\e[99;5u": "\C-c"'* ]]
  [[ "$output" == *'"\e[99;133u": "\C-c"'* ]]
  [[ "$output" == *'"\e[100;5u": "\C-d"'* ]]
  [[ "$output" == *'"\e[100;133u": "\C-d"'* ]]
}

@test "/model selects and persists a model via fzf" {
  stub_bin="$BATS_TEST_TMPDIR/bin"
  make_stub_command "$stub_bin" fzf 'head -n 1'
  PATH="$stub_bin:/usr/bin:/bin"

  provider_demo_list_models() {
    printf '[{"id":"model-a","label":"Model A"},{"id":"model-b","label":"Model B"}]\n'
  }

  baish_model_select_interactive 'demo'

  [ "$BAISH_ACTIVE_PROVIDER" = 'demo' ]
  [ "$BAISH_ACTIVE_MODEL" = 'model-a' ]
  [ "$(baish_state_selected_provider)" = 'demo' ]
  [ "$(baish_state_selected_model)" = 'model-a' ]
}

@test "process input preserves embedded newlines after slash commands" {
  mkdir -p "$TEST_PROJECT/.baish/skills/tdd"
  printf 'project tdd\n' >"$TEST_PROJECT/.baish/skills/tdd/SKILL.md"

  baish_process_input_line $'/skill:tdd\nFix line one\nFix line two'

  [ "${BAISH_TEST_AGENT_CALLS:-0}" -eq 1 ]
  [ "$BAISH_TEST_AGENT_LAST_MESSAGE" = $'Fix line one\nFix line two' ]
}

@test "process input preserves trailing newlines in real messages" {
  baish_process_input_line $'Investigate this\n\n'

  [ "${BAISH_TEST_AGENT_CALLS:-0}" -eq 1 ]
  [ "$BAISH_TEST_AGENT_LAST_MESSAGE" = $'Investigate this\n\n' ]
}

@test "process input ignores whitespace-only multiline drafts" {
  baish_process_input_line $' \n\t\n '

  [ "${BAISH_TEST_AGENT_CALLS:-0}" -eq 0 ]
}

@test "process input ignores slash commands followed only by separator whitespace" {
  baish_process_input_line $'/new\n\n'

  [ "${BAISH_TEST_AGENT_CALLS:-0}" -eq 0 ]
  [ "${#BAISH_SESSION_MESSAGES[@]}" -eq 0 ]
}

@test "/connect authenticates and persists the selected model" {
  stub_bin="$BATS_TEST_TMPDIR/bin"
  make_stub_command "$stub_bin" fzf 'tail -n 1'
  PATH="$stub_bin:/usr/bin:/bin"
  BAISH_PROVIDER='demo'

  provider_demo_auth() {
    baish_state_write_auth_json 'demo' '{"access_token":"token-123"}'
  }

  provider_demo_list_models() {
    printf '["model-a","model-b"]\n'
  }

  baish_slash_parse_line '/connect'
  baish_slash_execute_commands

  [ -f "$TEST_HOME/.baish/auth/demo.json" ]
  [ "$(jq -r '.access_token' "$TEST_HOME/.baish/auth/demo.json")" = 'token-123' ]
  [ "$(baish_state_selected_provider)" = 'demo' ]
  [ "$(baish_state_selected_model)" = 'model-b' ]
}
