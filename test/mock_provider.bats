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
  source "$REPO_ROOT/lib/agent.sh"
  source "$REPO_ROOT/lib/tools.sh"
  source "$REPO_ROOT/lib/providers/mock.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"
  BAISH_LAUNCH_CWD="$TEST_PROJECT"

  unset BAISH_MOCK_SCENARIO
  unset BAISH_MODEL
  unset BAISH_PROVIDER
  unset BAISH_ACTIVE_PROVIDER
  unset BAISH_ACTIVE_MODEL

  baish_state_init
}

mock_request_with_tool_result() {
  local scenario="$1"
  local assistant_response_json="$2"
  local tool_results_json="$3"

  jq -cn \
    --arg scenario "$scenario" \
    --argjson assistant "$assistant_response_json" \
    --argjson tool_results "$tool_results_json" \
    '
      {
        messages:
          ([{role: "user", content: "Run the mock scenario."}]
          + [{role: "assistant", tool_calls: $assistant.tool_calls}]
          + ($tool_results | to_entries | map({
              role: "tool",
              tool_call_id: $assistant.tool_calls[.key].id,
              name: $assistant.tool_calls[.key].name,
              result: .value
            }))),
        mock: {scenario: $scenario}
      }
    '
}

@test "mock provider auth writes state and list_models returns deterministic models" {
  local models_json auth_file

  baish_provider_call mock auth
  models_json="$(baish_provider_list_models_json mock)"
  auth_file="$TEST_HOME/.baish/auth/mock.json"

  [ -f "$auth_file" ]
  [ "$(stat -c '%a' "$auth_file")" = '600' ]
  [ "$(jq -r '.authenticated' "$auth_file")" = 'true' ]
  [ "$(jq -r 'length' <<<"$models_json")" = '3' ]
  [ "$(jq -r '.[0].id' <<<"$models_json")" = 'mock-text' ]
  [ "$(jq -r '.[1].id' <<<"$models_json")" = 'mock-tools' ]
  [ "$(jq -r '.[2].id' <<<"$models_json")" = 'mock-loop' ]
}

@test "mock provider returns a validated text-only chat response" {
  local response_json

  baish_provider_call mock auth
  response_json="$(baish_provider_chat_json mock '{"messages":[{"role":"user","content":"hello"}],"mock":{"scenario":"simple_text","final_text":"Mock says hi."}}')"

  [ "$(jq -r '.assistant_text' <<<"$response_json")" = 'Mock says hi.' ]
  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '0' ]
}

@test "mock provider single tool scenario can round-trip through tool execution" {
  local request_json response_json tool_name tool_arguments tool_result next_request_json final_response_json

  baish_provider_call mock auth
  request_json='{"messages":[{"role":"user","content":"Run one tool."}],"mock":{"scenario":"single_tool_then_final","command":"printf single-tool-output"}}'
  response_json="$(baish_provider_chat_json mock "$request_json")"

  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '1' ]
  tool_name="$(jq -r '.tool_calls[0].name' <<<"$response_json")"
  tool_arguments="$(jq -c '.tool_calls[0].arguments' <<<"$response_json")"
  tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")"

  next_request_json="$(mock_request_with_tool_result 'single_tool_then_final' "$response_json" "[$tool_result]")"
  final_response_json="$(baish_provider_chat_json mock "$next_request_json")"

  [ "$(jq -r '.ok' <<<"$tool_result")" = 'true' ]
  [ "$(jq -r '.data.stdout' <<<"$tool_result")" = 'single-tool-output' ]
  [ "$(jq -r '.tool_calls | length' <<<"$final_response_json")" = '0' ]
  [ "$(jq -r '.assistant_text' <<<"$final_response_json")" = 'Mock completed the single-tool scenario.' ]
}

@test "mock provider multiple tool scenario returns both calls and then finishes" {
  local request_json response_json tool_results_json next_request_json final_response_json
  local tool_index tool_name tool_arguments tool_result

  baish_provider_call mock auth
  request_json='{"messages":[{"role":"user","content":"Run multiple tools."}],"mock":{"scenario":"multiple_tools_then_final","first_command":"printf first","second_command":"printf second >&2; exit 3"}}'
  response_json="$(baish_provider_chat_json mock "$request_json")"

  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '2' ]

  tool_results_json='[]'
  for tool_index in 0 1; do
    tool_name="$(jq -r ".tool_calls[$tool_index].name" <<<"$response_json")"
    tool_arguments="$(jq -c ".tool_calls[$tool_index].arguments" <<<"$response_json")"
    tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")"
    tool_results_json="$(jq -cn --argjson results "$tool_results_json" --argjson result "$tool_result" '$results + [$result]')"
  done

  next_request_json="$(mock_request_with_tool_result 'multiple_tools_then_final' "$response_json" "$tool_results_json")"
  final_response_json="$(baish_provider_chat_json mock "$next_request_json")"

  [ "$(jq -r '.[0].data.stdout' <<<"$tool_results_json")" = 'first' ]
  [ "$(jq -r '.[1].data.stderr' <<<"$tool_results_json")" = 'second' ]
  [ "$(jq -r '.[1].data.exit_code' <<<"$tool_results_json")" = '3' ]
  [ "$(jq -r '.tool_calls | length' <<<"$final_response_json")" = '0' ]
  [ "$(jq -r '.assistant_text' <<<"$final_response_json")" = 'Mock completed 2 tool calls.' ]
}

@test "mock provider loop scenario keeps returning tool calls" {
  local request_json response_json tool_name tool_arguments tool_result next_request_json follow_up_response_json

  baish_provider_call mock auth
  request_json='{"messages":[{"role":"user","content":"Loop forever."}],"mock":{"scenario":"loop_forever","command":"printf looped"}}'
  response_json="$(baish_provider_chat_json mock "$request_json")"

  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '1' ]
  [ "$(jq -r '.assistant_text' <<<"$response_json")" = 'null' ]

  tool_name="$(jq -r '.tool_calls[0].name' <<<"$response_json")"
  tool_arguments="$(jq -c '.tool_calls[0].arguments' <<<"$response_json")"
  tool_result="$(baish_tool_execute_json "$tool_name" "$tool_arguments")"
  next_request_json="$(mock_request_with_tool_result 'loop_forever' "$response_json" "[$tool_result]")"
  follow_up_response_json="$(baish_provider_chat_json mock "$next_request_json")"

  [ "$(jq -r '.tool_calls | length' <<<"$follow_up_response_json")" = '1' ]
  [ "$(jq -r '.tool_calls[0].id' <<<"$follow_up_response_json")" = 'mock-loop-call' ]
}

@test "launcher can connect to the mock provider offline" {
  local stub_bin auth_file state_file

  stub_bin="$BATS_TEST_TMPDIR/bin"
  make_stub_command "$stub_bin" fzf 'head -n 1'
  make_stub_command "$stub_bin" bat 'exit 0'
  make_stub_command "$stub_bin" gawk 'if [[ "${1-}" == "--version" ]]; then
  printf "GNU Awk 5.0\n"
  exit 0
fi
exit 0'

  run bash -lc 'printf "/connect\n/quit\n" | env HOME="$1" BAISH_PROVIDER=mock PATH="$2:/usr/bin:/bin" "$3/bin/baish"' bash "$TEST_HOME" "$stub_bin" "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"BAISH ready. Use /quit to exit."* ]]
  [[ "$output" == *"Selected model: mock-text"* ]]
  [[ "$output" == *"Connected provider: mock"* ]]

  auth_file="$TEST_HOME/.baish/auth/mock.json"
  state_file="$TEST_HOME/.baish/state.json"

  [ -f "$auth_file" ]
  [ "$(jq -r '.authenticated' "$auth_file")" = 'true' ]
  [ -f "$state_file" ]
  [ "$(jq -r '.selected_provider' "$state_file")" = 'mock' ]
  [ "$(jq -r '.selected_model' "$state_file")" = 'mock-text' ]
}

@test "interactive launcher shows the startup header and first idle footer" {
  local stub_bin

  stub_bin="$BATS_TEST_TMPDIR/bin"
  make_stub_command "$stub_bin" fzf 'exit 0'
  make_stub_command "$stub_bin" bat 'exit 0'
  make_stub_command "$stub_bin" gawk 'if [[ "${1-}" == "--version" ]]; then
  printf "GNU Awk 5.0\n"
  exit 0
fi
exit 0'

  run bash -lc 'cd "$1" && printf "/quit\n" | script -qec "env HOME=\"$2\" BAISH_PROVIDER=mock BAISH_MODEL=mock-text PATH=\"$3:/usr/bin:/bin\" \"$4/bin/baish\"" /dev/null | tr -d "\r"' bash "$TEST_PROJECT" "$TEST_HOME" "$stub_bin" "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"BAISH · AI Coding Assistant for Bash"* ]]
  [[ "$output" == *"Slash commands:"* ]]
  [[ "$output" == *"────────────────────────────────────────────────────────────────────────────────"* ]]
  [[ "$output" == *"$TEST_PROJECT · Mock Provider · mock-text"* ]]
}

@test "non-interactive launcher output stays footer-free" {
  local stub_bin

  stub_bin="$BATS_TEST_TMPDIR/bin"
  make_stub_command "$stub_bin" fzf 'exit 0'
  make_stub_command "$stub_bin" bat 'exit 0'
  make_stub_command "$stub_bin" gawk 'if [[ "${1-}" == "--version" ]]; then
  printf "GNU Awk 5.0\n"
  exit 0
fi
exit 0'

  run bash -lc 'cd "$1" && printf "/quit\n" | env HOME="$2" BAISH_PROVIDER=mock BAISH_MODEL=mock-text PATH="$3:/usr/bin:/bin" "$4/bin/baish"' bash "$TEST_PROJECT" "$TEST_HOME" "$stub_bin" "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = 'BAISH ready. Use /quit to exit.' ]
}
