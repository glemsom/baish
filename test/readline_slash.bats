#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"

  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  cd "$TEST_PROJECT"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/slash.sh"
  source "$REPO_ROOT/lib/readline.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"

  unset BAISH_MODEL
  unset BAISH_PROVIDER
  unset BAISH_ACTIVE_PROVIDER
  unset BAISH_ACTIVE_MODEL

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

@test "slash parser handles multiple slash commands before chat text" {
  baish_slash_parse_line '/skill:tdd /skill:pirate Fix the auth bug'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 2 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'skill' ]
  [ "${BAISH_SLASH_ARGS[0]}" = 'tdd' ]
  [ "${BAISH_SLASH_COMMANDS[1]}" = 'skill' ]
  [ "${BAISH_SLASH_ARGS[1]}" = 'pirate' ]
  [ "$BAISH_SLASH_REMAINING_TEXT" = 'Fix the auth bug' ]
}

@test "slash-looking text after chat begins remains chat text" {
  baish_slash_parse_line '/skill:tdd Fix /skill:pirate later'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'skill' ]
  [ "$BAISH_SLASH_REMAINING_TEXT" = 'Fix /skill:pirate later' ]
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

@test "/exit aliases /quit" {
  baish_slash_parse_line '/exit'

  [ "${#BAISH_SLASH_COMMANDS[@]}" -eq 1 ]
  [ "${BAISH_SLASH_COMMANDS[0]}" = 'quit' ]
}

@test "skill loading prefers project-local skills, falls back to user skills, and stays idempotent" {
  mkdir -p "$TEST_PROJECT/.baish/skills" "$TEST_HOME/.baish/skills"
  printf 'project tdd\n' >"$TEST_PROJECT/.baish/skills/tdd.md"
  printf 'user tdd\n' >"$TEST_HOME/.baish/skills/tdd.md"
  printf 'user pirate\n' >"$TEST_HOME/.baish/skills/pirate.md"

  baish_skill_load 'tdd'
  baish_skill_load 'pirate'
  baish_skill_load 'tdd'

  [ "${#BAISH_SESSION_SKILL_NAMES[@]}" -eq 2 ]
  [ "${BAISH_SESSION_SKILL_NAMES[0]}" = 'tdd' ]
  [ "${BAISH_SESSION_SKILL_NAMES[1]}" = 'pirate' ]
  [ "${BAISH_SESSION_SKILL_PATHS[0]}" = "$TEST_PROJECT/.baish/skills/tdd.md" ]
  [ "${BAISH_SESSION_SKILL_PATHS[1]}" = "$TEST_HOME/.baish/skills/pirate.md" ]
  [ "${BAISH_SESSION_SKILL_CONTENTS[0]}" = 'project tdd' ]
  [ "${BAISH_SESSION_SKILL_CONTENTS[1]}" = 'user pirate' ]
}

@test "slash completion supports commands, skills, and multiple slash commands on one line" {
  mkdir -p "$TEST_PROJECT/.baish/skills" "$TEST_HOME/.baish/skills"
  printf 'project tdd\n' >"$TEST_PROJECT/.baish/skills/tdd.md"
  printf 'user pirate\n' >"$TEST_HOME/.baish/skills/pirate.md"

  run bash -lc '
    source "$1/lib/state.sh"
    source "$1/lib/slash.sh"
    HOME="$2"
    cd "$3"
    baish_state_init
    baish_session_reset
    baish_slash_completion_candidates "/sk" 3
    printf -- "--\n"
    baish_slash_completion_candidates "/skill:t" 8
    printf -- "--\n"
    baish_slash_completion_candidates "/skill:tdd /sk" 14
  ' bash "$REPO_ROOT" "$TEST_HOME" "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  [[ "$output" == $'/skill:\n--\n/skill:tdd\n--\n/skill:'* ]]
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
