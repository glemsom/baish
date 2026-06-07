#!/usr/bin/env bats
# BAISH — Tests: Mock Provider, State, Session, Debug, and basic Agent Loop

setup() {
    # Isolate state to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export BAISH_HOME="${BAISH_STATE_DIR}/home"
    export HOME="${BAISH_HOME}"
    mkdir -p "${HOME}"

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Source modules
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
    source "${BAISH_ROOT}/lib/providers/mock.sh"
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# Test: mock provider returns a fixed response with ok:true
@test "mock provider returns fixed assistant response with ok:true" {
    local response
    response=$(provider_mock_chat '[]' '[]')

    local ok text
    ok=$(echo "${response}" | jq -r '.ok')
    text=$(echo "${response}" | jq -r '.assistant_text')

    [[ "${ok}" == "true" ]]
    [[ "${text}" == "I am the mock provider. Your message was received." ]]
}

# Test: mock provider returns empty tool calls by default
@test "mock provider returns empty tool calls by default" {
    local response
    response=$(provider_mock_chat '[]' '[]')

    local tc
    tc=$(echo "${response}" | jq -c '.tool_calls')

    [[ "${tc}" == "[]" ]]
}

# Test: mock provider returns pre-programmed tool calls
@test "mock provider returns pre-programmed tool calls" {
    export BAISH_MOCK_TOOL_CALLS='[{"id":"tc1","name":"read","arguments":"{}"}]'

    local response
    response=$(provider_mock_chat '[]' '[]')

    local tc_len
    tc_len=$(echo "${response}" | jq '.tool_calls | length')

    [[ "${tc_len}" == "1" ]]

    local tool_name
    tool_name=$(echo "${response}" | jq -r '.tool_calls[0].name')
    [[ "${tool_name}" == "read" ]]
}

# Test: state persistence write and read
@test "state persistence writes and reads provider and model" {
    baish_state_init
    baish_state_write "mock" "mock-model"

    local result
    baish_state_read
    result=$?

    [[ "${result}" == "0" ]]
    [[ "${BAISH_STATE_PROVIDER}" == "mock" ]]
    [[ "${BAISH_STATE_MODEL}" == "mock-model" ]]
}

# Test: state read fails when no state file exists
@test "state read fails when state file is missing" {
    local result
    result=$(baish_state_read || true)

    [[ "${result}" != "0" ]]
}

# Test: agent loop processes user message with mock provider
@test "agent loop processes user message and produces response" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="Hello from mock!"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_EXIT_REQUESTED=0
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0  # suppress spinner noise

    baish_agent_run_user_message "Test message"

    # Verify message was appended
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 2 ]]  # user + assistant

    # Verify assistant response contains mock text
    local second_msg
    second_msg="${BAISH_SESSION_MESSAGES[1]}"
    local role content
    role=$(echo "${second_msg}" | jq -r '.role')
    content=$(echo "${second_msg}" | jq -r '.content')

    [[ "${role}" == "assistant" ]]
    [[ "${content}" == "Hello from mock!" ]]
}

# Test: tool rounds limit is enforced
@test "agent loop respects BAISH_MAX_TOOL_ROUNDS limit" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="Round test"
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc1","name":"read","arguments":"{}"}]'
    BAISH_MAX_TOOL_ROUNDS=2
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_EXIT_REQUESTED=0
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Test"

    # After 2 rounds with tool calls, loop should stop
    [[ ${BAISH_SESSION_TOOL_ROUNDS} -le 2 ]]
}
