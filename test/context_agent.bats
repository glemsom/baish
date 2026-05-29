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
  unset BAISH_MOCK_PHASE
  unset BAISH_MOCK_READ_PATHS_JSON

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
  CAPTURE_OUTPUT_PLAIN="$(strip_ansi "$CAPTURE_OUTPUT")"
  return 0
}

strip_ansi() {
  printf '%s' "$1" | tr -d '\r' | sed -E $'s/\x1B\[[0-9;]*m//g'
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

@test "context JSON builders handle conversations larger than ARG_MAX" {
  local arg_max chunk_size message_count large_chunk messages_json request_json

  arg_max="$(getconf ARG_MAX)"
  chunk_size=65536
  message_count=$(( arg_max / chunk_size + 2 ))
  printf -v large_chunk '%*s' "$chunk_size" ''
  large_chunk="${large_chunk// /x}"

  for ((i = 0; i < message_count; i++)); do
    baish_agent_append_user_message "$large_chunk"
  done

  messages_json="$(baish_context_messages_json)"
  request_json="$(baish_context_build_request_json 'mock-tools' "$messages_json")"

  [ "$(jq -r 'length' <<<"$messages_json")" = "$message_count" ]
  [ "$(jq -r '.messages | length' <<<"$request_json")" = "$message_count" ]
  [ "$(jq -r '.[0].content | length' <<<"$messages_json")" = "$chunk_size" ]
}

@test "tool call summarizer formats read edit write and bash previews" {
  local read_summary edit_summary write_summary bash_summary

  read_summary="$(baish_agent_summarize_tool_call read '{"path":"README.md","offset":2,"limit":3}')"
  edit_summary="$(baish_agent_summarize_tool_call edit '{"path":"lib/agent.sh","edits":[{"oldText":"a","newText":"b"},{"oldText":"c","newText":"d"}]}')"
  write_summary="$(baish_agent_summarize_tool_call write '{"path":"docs/out.txt","content":"hello"}')"
  bash_summary="$(baish_agent_summarize_tool_call bash '{"command":"printf first\nprintf second\n"}')"

  [ "$read_summary" = 'README.md:2-4' ]
  [ "$edit_summary" = 'lib/agent.sh (2 replacements)' ]
  [ "$write_summary" = 'docs/out.txt' ]
  [ "$bash_summary" = 'printf first printf second' ]
}

@test "tool result summarizer reports edit failures concisely" {
  local summary_json

  summary_json="$(baish_agent_summarize_tool_result edit '{"ok":false,"tool":"edit","error":{"code":"old_text_not_found","message":"edit entry 0 oldText was not found exactly once."}}')"

  [ "$(jq -r '.status' <<<"$summary_json")" = 'failure' ]
  [ "$(jq -r '.footer' <<<"$summary_json")" = 'edit failed' ]
  [ "$(jq -r '.detail' <<<"$summary_json")" = 'old_text_not_found: edit entry 0 oldText was not found exactly once.' ]
}

@test "bash tool result summarizer keeps the last 10 output lines" {
  local summary_json stdout_text expected_tail

  stdout_text="$(printf 'line-%02d\n' {1..12})"
  expected_tail="$(printf 'line-%02d\n' {3..12})"
  expected_tail="${expected_tail%$'\n'}"
  summary_json="$(baish_agent_summarize_tool_result bash "$(jq -cn --arg stdout "$stdout_text" '{ok: true, tool: "bash", data: {exit_code: 0, stdout: $stdout, stderr: ""}}')")"

  [ "$(jq -r '.status' <<<"$summary_json")" = 'success' ]
  [ "$(jq -r '.summary' <<<"$summary_json")" = 'completed with output' ]
  [ "$(jq -r '.detail' <<<"$summary_json")" = "$expected_tail" ]
}

@test "chat response validation accepts optional non-empty phase and rejects invalid phase values" {
  run baish_provider_chat_response_valid '{"assistant_text":null,"tool_calls":[]}'
  [ "$status" -eq 0 ]

  run baish_provider_chat_response_valid '{"assistant_text":null,"tool_calls":[],"phase":"Inspect runtime"}'
  [ "$status" -eq 0 ]

  run baish_provider_chat_response_valid '{"assistant_text":null,"tool_calls":[],"phase":""}'
  [ "$status" -eq 1 ]

  run baish_provider_chat_response_valid '{"assistant_text":null,"tool_calls":[],"phase":123}'
  [ "$status" -eq 1 ]
}

@test "read path collection preserves order and deduplicates exact duplicate paths" {
  local response_json paths_json joined_paths

  response_json='{"assistant_text":null,"tool_calls":[{"id":"read-1","name":"read","arguments":{"path":"README.md"}},{"id":"bash-1","name":"bash","arguments":{"command":"printf hi"}},{"id":"read-2","name":"read","arguments":{"path":"lib/agent.sh","offset":1,"limit":10}},{"id":"read-3","name":"read","arguments":{"path":"README.md"}}]}'
  paths_json="$(baish_agent_collect_read_paths_json "$response_json")"
  joined_paths="$(baish_agent_join_paths_for_display "$paths_json")"

  [ "$paths_json" = '["README.md","lib/agent.sh"]' ]
  [ "$joined_paths" = 'README.md, lib/agent.sh' ]
}

@test "phase fallback selection uses inspect files for read-only rounds and use tools otherwise" {
  [ "$(baish_agent_phase_label '{"assistant_text":null,"tool_calls":[{"id":"read-1","name":"read","arguments":{"path":"README.md"}}]}')" = 'Inspect files' ]
  [ "$(baish_agent_phase_label '{"assistant_text":null,"tool_calls":[{"id":"read-1","name":"read","arguments":{"path":"README.md"}},{"id":"bash-1","name":"bash","arguments":{"command":"printf hi"}}]}')" = 'Use tools' ]
  [ "$(baish_agent_phase_label '{"assistant_text":null,"tool_calls":[{"id":"bash-1","name":"bash","arguments":{"command":"printf hi"}}],"phase":"Compare impl with tests"}')" = 'Compare impl with tests' ]
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
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'user> Hello BAISH'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'Selected model: mock-text'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'Connected provider: mock'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'assistant> Mock connected hello.'* ]]

  auth_file="$TEST_HOME/.baish/auth/mock.json"
  state_file="$TEST_HOME/.baish/state.json"
  [ -f "$auth_file" ]
  [ -f "$state_file" ]
  [ "$(jq -r '.selected_provider' "$state_file")" = 'mock' ]
  [ "$(jq -r '.selected_model' "$state_file")" = 'mock-text' ]
}

@test "/new starts a fresh chat without reconnecting" {
  local messages_json

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-text'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-text'
  export BAISH_MOCK_SCENARIO='simple_text'
  export BAISH_MOCK_FINAL_TEXT='Mock hello.'

  capture_process_input_line 'First chat'
  [ "$CAPTURE_STATUS" -eq 0 ]
  [ "$(jq -r 'length' <<<"$(baish_context_messages_json)")" = '2' ]

  export BAISH_MOCK_FINAL_TEXT='Mock fresh chat.'
  capture_process_input_line '/new Second chat'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'Started new chat.'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'user> Second chat'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'assistant> Mock fresh chat.'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'Connected provider: mock'* ]]
  [ "$(jq -r 'length' <<<"$messages_json")" = '2' ]
  [ "$(jq -r '.[0].content' <<<"$messages_json")" = 'Second chat' ]
}

@test "agent loop renders a successful tool round and appends the structured tool result" {
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
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╭─ Phase: Use tools'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'│ ⚙️ bash'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'printf single-tool-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'↳ completed with output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'     single-tool-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╰─ ✅ completed'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'tool> bash'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'tool_result>'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'assistant> Mock completed the single-tool scenario.'* ]]
  [ "$(jq -r 'length' <<<"$messages_json")" = '4' ]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '1' ]
  [ "$(jq -r '[.[] | select(.role == "tool")][0].result.data.stdout' <<<"$messages_json")" = 'single-tool-output' ]
}

@test "agent loop groups read-only rounds into a phase block and persists the phase" {
  local messages_json

  printf 'readme\n' >"$TEST_PROJECT/README.md"
  printf 'agent\n' >"$TEST_PROJECT/agent.sh"

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='read_only_then_final'
  export BAISH_MOCK_PHASE='Inspect core runtime flow'
  export BAISH_MOCK_READ_PATHS_JSON='["README.md","agent.sh","README.md"]'

  capture_process_input_line 'Inspect the core runtime.'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╭─ Phase: Inspect core runtime flow'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'│ Files: README.md, agent.sh'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'│ 📖 read'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╰─ ✅ completed'* ]]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '3' ]
  [ "$(jq -r '[.[] | select(.role == "assistant")][0].phase' <<<"$messages_json")" = 'Inspect core runtime flow' ]
}

@test "agent loop groups read files in mixed rounds and still renders non-read tool rows" {
  local messages_json

  printf 'readme\n' >"$TEST_PROJECT/README.md"
  printf 'agent\n' >"$TEST_PROJECT/agent.sh"

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='mixed_read_bash_then_final'
  export BAISH_MOCK_PHASE='Compare impl with tests'
  export BAISH_MOCK_READ_PATHS_JSON='["README.md","agent.sh","README.md"]'
  export BAISH_MOCK_COMMAND='printf mixed-output'

  capture_process_input_line 'Compare implementation with tests.'
  messages_json="$(baish_context_messages_json)"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╭─ Phase: Compare impl with tests'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'│ Files: README.md, agent.sh'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" != *'│ 📖 read'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'│ ⚙️ bash'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'printf mixed-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'↳ completed with output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'     mixed-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'assistant> Mock completed the mixed tool scenario.'* ]]
  [ "$(jq -r '[.[] | select(.role == "tool")] | length' <<<"$messages_json")" = '4' ]
}

@test "agent loop uses inspect files as the fallback phase for read-only rounds" {
  printf 'readme\n' >"$TEST_PROJECT/README.md"

  baish_provider_call mock auth
  baish_state_set_selected_provider_model 'mock' 'mock-tools'
  BAISH_ACTIVE_PROVIDER='mock'
  BAISH_ACTIVE_MODEL='mock-tools'
  export BAISH_MOCK_SCENARIO='read_only_then_final'
  export BAISH_MOCK_READ_PATHS_JSON='["README.md"]'

  capture_process_input_line 'Inspect one file.'

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╭─ Phase: Inspect files'* ]]
}

@test "agent loop renders bash non-zero exits as failures and still appends both tool results" {
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
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╭─ Phase: Use tools'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'printf first-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'printf second-output >&2; exit 3'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'↳ completed with output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'     first-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'╰─ ❌ bash failed (exit 3)'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'     stderr:'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'second-output'* ]]
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'assistant> Mock completed 2 tool calls.'* ]]
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
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'BAISH stopped because the max tool rounds limit (2) was exceeded.'* ]]
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
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'BAISH stopped because the max tool calls limit (1) was exceeded.'* ]]
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
  [[ "$CAPTURE_OUTPUT_PLAIN" == *'BAISH could not continue because the tool output exceeded the model context window. Retry with a narrower command or ask BAISH to inspect a smaller file range.'* ]]
}
