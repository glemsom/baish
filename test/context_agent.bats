#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"

  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  cd "$TEST_PROJECT"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/slash.sh"
  source "$REPO_ROOT/lib/context.sh"
  source "$REPO_ROOT/lib/agent.sh"
  source "$REPO_ROOT/lib/tools.sh"
  source "$REPO_ROOT/lib/providers/mock.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"
  BAISH_LAUNCH_CWD="$TEST_PROJECT"

  unset BAISH_DEBUG
  unset BAISH_MODEL
  unset BAISH_PROVIDER
  unset BAISH_ACTIVE_PROVIDER
  unset BAISH_ACTIVE_MODEL
  unset BAISH_MAX_TOOL_ROUNDS
  unset BAISH_MAX_TOOL_CALLS
  unset BAISH_MOCK_SCENARIO
  unset BAISH_MOCK_FINAL_TEXT
  unset BAISH_MOCK_COMMAND
  unset BAISH_MOCK_FIRST_COMMAND
  unset BAISH_MOCK_SECOND_COMMAND

  baish_state_init
  baish_session_reset
}

capture_process_input_line() {
  local line="$1"
  local output_file="$BATS_TEST_TMPDIR/process-output"

  : >"$output_file"
  set +e
  baish_process_input_line "$line" >"$output_file" 2>&1
  CAPTURE_STATUS=$?
  set -e
  CAPTURE_OUTPUT="$(<"$output_file")"
  return 0
}

@test "context request keeps a byte-stable prefix when only conversation changes" {
  local request_one request_two prefix_one prefix_two

  mkdir -p "$TEST_PROJECT/.baish/skills"
  printf 'Use tiny steps.\n' >"$TEST_PROJECT/.baish/skills/tdd.md"

  baish_skill_load 'tdd'
  request_one="$(baish_context_build_request_json 'mock-tools' '[{"role":"user","content":"hello one"}]')"
  request_two="$(baish_context_build_request_json 'mock-tools' '[{"role":"user","content":"hello one"},{"role":"assistant","content":"done"},{"role":"user","content":"hello two"}]')"
  prefix_one="$(jq -c 'del(.messages)' <<<"$request_one")"
  prefix_two="$(jq -c 'del(.messages)' <<<"$request_two")"

  [ "$prefix_one" = "$prefix_two" ]
  [ "$(jq -r '.skills[0].name' <<<"$request_one")" = 'tdd' ]
  [ "$(jq -r '.skills[0].content' <<<"$request_one")" = 'Use tiny steps.' ]
  [ "$(jq -c 'keys_unsorted' <<<"$request_one")" = '["model","system_prompt","tools","tool_use_instructions","skills","messages"]' ]
}

@test "first chat auto-connects and then returns the assistant response" {
  local stub_bin auth_file state_file

  stub_bin="$BATS_TEST_TMPDIR/bin"
  make_stub_command "$stub_bin" fzf 'head -n 1'
  export PATH="$stub_bin:/usr/bin:/bin"
  export BAISH_PROVIDER='mock'
  export BAISH_MOCK_SCENARIO='simple_text'
  export BAISH_MOCK_FINAL_TEXT='Mock connected hello.'

  capture_process_input_line 'Hello BAISH'

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT" == *'user> Hello BAISH'* ]]
  [[ "$CAPTURE_OUTPUT" == *'Selected model: mock-text'* ]]
  [[ "$CAPTURE_OUTPUT" == *'Connected provider: mock'* ]]
  [[ "$CAPTURE_OUTPUT" == *'assistant> Mock connected hello.'* ]]

  auth_file="$TEST_HOME/.baish/auth/mock.json"
  state_file="$TEST_HOME/.baish/state.json"
  [ -f "$auth_file" ]
  [ -f "$state_file" ]
  [ "$(jq -r '.selected_provider' "$state_file")" = 'mock' ]
  [ "$(jq -r '.selected_model' "$state_file")" = 'mock-text' ]
}

@test "agent loop executes one tool call and appends the structured tool result" {
  local messages_json

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='single_tool_then_final'
  export BAISH_MOCK_COMMAND='printf single-tool-output'

  capture_process_input_line 'Run one tool.'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT" == *'tool> bash {"command":"printf single-tool-output"}'* ]]
  [[ "$CAPTURE_OUTPUT" == *'"stdout":"single-tool-output"'* ]]
  [[ "$CAPTURE_OUTPUT" == *'assistant> Mock completed the single-tool scenario.'* ]]
  [ "$(jq -r 'length' <<<"$messages_json")" = '4' ]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '1' ]
  [ "$(jq -r '[.[] | select(.role == "tool")][0].result.data.stdout' <<<"$messages_json")" = 'single-tool-output' ]
}

@test "agent loop executes all tool calls returned in one provider response" {
  local messages_json

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='multiple_tools_then_final'
  export BAISH_MOCK_FIRST_COMMAND='printf first-output'
  export BAISH_MOCK_SECOND_COMMAND='printf second-output >&2; exit 3'

  capture_process_input_line 'Run multiple tools.'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT" == *'tool> bash {"command":"printf first-output"}'* ]]
  [[ "$CAPTURE_OUTPUT" == *'tool> bash {"command":"printf second-output >&2; exit 3"}'* ]]
  [[ "$CAPTURE_OUTPUT" == *'assistant> Mock completed 2 tool calls.'* ]]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '2' ]
  [ "$(jq -r '[.[] | select(.role == "tool")][0].result.data.stdout' <<<"$messages_json")" = 'first-output' ]
  [ "$(jq -r '[.[] | select(.role == "tool")][1].result.data.stderr' <<<"$messages_json")" = 'second-output' ]
  [ "$(jq -r '[.[] | select(.role == "tool")][1].result.data.exit_code' <<<"$messages_json")" = '3' ]
}

@test "agent loop stops when the max tool rounds limit is exceeded" {
  local messages_json

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-loop'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-loop'
  export BAISH_MOCK_SCENARIO='loop_forever'
  export BAISH_MOCK_COMMAND='printf looped'
  BAISH_MAX_TOOL_ROUNDS=2

  capture_process_input_line 'Loop forever.'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 1 ]
  [[ "$CAPTURE_OUTPUT" == *'BAISH stopped because the max tool rounds limit (2) was exceeded.'* ]]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '2' ]
}

@test "agent loop stops when the max tool calls limit is exceeded" {
  local messages_json

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='multiple_tools_then_final'
  export BAISH_MOCK_FIRST_COMMAND='printf first-output'
  export BAISH_MOCK_SECOND_COMMAND='printf second-output >&2; exit 3'
  BAISH_MAX_TOOL_CALLS=1

  capture_process_input_line 'Only one tool call is allowed.'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 1 ]
  [[ "$CAPTURE_OUTPUT" == *'BAISH stopped because the max tool calls limit (1) was exceeded.'* ]]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '1' ]
}

@test "context overflow becomes a BAISH-level failure" {
  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='context_overflow'

  capture_process_input_line 'Overflow the model.'

  [ "$CAPTURE_STATUS" -eq 1 ]
  [[ "$CAPTURE_OUTPUT" == *'BAISH could not continue because the tool output exceeded the model context window. Retry with a narrower command or ask BAISH to inspect a smaller file range.'* ]]
}
