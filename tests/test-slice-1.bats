#!/usr/bin/env bats
# BAISH — Test: mock provider end-to-end
# Exercises the agent loop with the mock provider, verifying that a user
# message produces an assistant response.

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
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# Test: mock provider returns a fixed response
@test "mock provider returns fixed assistant response" {
    local response
    response=$(provider_mock_chat '[]' '[]')

    local text
    text=$(echo "${response}" | jq -r '.assistant_text')

    [[ "${text}" == "I am the mock provider. Your message was received." ]]
}

# Test: mock provider metadata is correct
@test "mock provider metadata is non-selectable" {
    local metadata
    metadata=$(provider_mock_metadata)

    local id selectable
    id=$(echo "${metadata}" | jq -r '.id')
    selectable=$(echo "${metadata}" | jq -r '.selectable')

    [[ "${id}" == "mock" ]]
    [[ "${selectable}" == "false" ]]
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

# Test: session reset clears messages
@test "session reset clears message history" {
    baish_session_append_user_message "hello"
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 1 ]]

    baish_session_reset_context_window
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 0 ]]
}

# Test: debug logging outputs when enabled
@test "debug logging outputs when BAISH_DEBUG=1" {
    BAISH_DEBUG=1
    local output
    output=$(baish_debug "test message" 2>&1)

    [[ "${output}" == *"[DEBUG] test message"* ]]
}

# Test: debug logging is silent when disabled
@test "debug logging is silent when BAISH_DEBUG=0" {
    BAISH_DEBUG=0
    local output
    output=$(baish_debug "test message" 2>&1)

    [[ -z "${output}" ]]
}

# Test: tool execution dispatches to stubs
@test "tool execution returns NOT_IMPLEMENTED for read tool" {
    local result
    result=$(baish_tool_execute "read" '{"path":"test.txt"}')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "NOT_IMPLEMENTED" ]]
}

# Test: agent loop processes user message with mock provider
@test "agent loop processes user message and produces response" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="Hello from mock!"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_EXIT_REQUESTED=0
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_SESSION_TOTAL_TOOL_CALLS=0
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
    BAISH_SESSION_TOTAL_TOOL_CALLS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Test"

    # After 2 rounds with tool calls, loop should stop
    [[ ${BAISH_SESSION_TOOL_ROUNDS} -le 2 ]]
}
