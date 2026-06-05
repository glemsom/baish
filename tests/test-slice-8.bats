#!/usr/bin/env bats
# BAISH - Test: Slice 8 - Error handling and resilience

setup() {
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT
    # Set up a shared stderr file for run-loop tests
    export BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr"
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/display.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/skills.sh"
    source "${BAISH_ROOT}/lib/agent/commands.sh"
    source "${BAISH_ROOT}/lib/agent/errors.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
    source "${BAISH_ROOT}/lib/providers/discovery.sh"
    source "${BAISH_ROOT}/lib/providers/mock.sh"
    source "${BAISH_ROOT}/lib/providers/copilot.sh"
    source "${BAISH_ROOT}/lib/providers/kilo.sh"
    source "${BAISH_ROOT}/lib/ui/completion.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
    rm -f "${BAISH_CHAT_STDERR_FILE:-}"
}

# ============================================================
# Error type detection
# ============================================================

@test "detects CONTEXT_OVERFLOW from context_length_exceeded pattern" {
    local stderr="Error: context_length_exceeded - input is too long"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "CONTEXT_OVERFLOW" ]]
}

@test "detects CONTEXT_OVERFLOW from context exceeded pattern" {
    local stderr="Request failed: context window exceeded maximum"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "CONTEXT_OVERFLOW" ]]
}

@test "detects CONTEXT_OVERFLOW from too long pattern" {
    local stderr="The prompt is too long for this model"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "CONTEXT_OVERFLOW" ]]
}

@test "detects CONTEXT_OVERFLOW from explicit CONTEXT_OVERFLOW signal" {
    local stderr="CONTEXT_OVERFLOW"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "CONTEXT_OVERFLOW" ]]
}

@test "detects TOKEN_EXPIRED from explicit signal" {
    local stderr="TOKEN_EXPIRED"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "TOKEN_EXPIRED" ]]
}

@test "detects TOKEN_EXPIRED from token expiry pattern" {
    local stderr="Authentication token expired at epoch 1234567890"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "TOKEN_EXPIRED" ]]
}

@test "detects AUTH_FAILURE from 401 status" {
    local stderr="HTTP 401 Unauthorized - invalid credentials"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "AUTH_FAILURE" ]]
}

@test "detects AUTH_FAILURE from 403 status" {
    local stderr="HTTP 403 Forbidden - access denied"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "AUTH_FAILURE" ]]
}

@test "detects AUTH_FAILURE from invalid key message" {
    local stderr="Invalid API key provided"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "AUTH_FAILURE" ]]
}

@test "detects AUTH_FAILURE from denied OAuth message" {
    local stderr="OAuth authorization was denied by the user"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "AUTH_FAILURE" ]]
}

@test "classifies unknown errors as GENERIC_ERROR" {
    local stderr="Something went wrong: connection reset"
    local result
    result=$(baish_detect_error_type "${stderr}")
    [[ "${result}" == "GENERIC_ERROR" ]]
}

@test "handles empty stderr as GENERIC_ERROR" {
    local result
    result=$(baish_detect_error_type "")
    [[ "${result}" == "GENERIC_ERROR" ]]
}

# ============================================================
# Context overflow handling
# ============================================================

@test "context overflow guidance mentions /new command" {
    local output
    output=$(baish_print_context_overflow_help 2>&1)
    [[ "${output}" == *"/new"* ]]
}

@test "context overflow guidance mentions context exceeded" {
    local output
    output=$(baish_print_context_overflow_help 2>&1)
    [[ "${output}" == *"context"* ]] || [[ "${output}" == *"exceeded"* ]]
}

# ============================================================
# Auth failure handling
# ============================================================

@test "auth failure message includes provider name" {
    local output
    output=$(baish_print_auth_failure "copilot" 2>&1)
    [[ "${output}" == *"copilot"* ]]
}

@test "auth failure message includes /connect guidance" {
    local output
    output=$(baish_print_auth_failure "kilo" 2>&1)
    [[ "${output}" == *"/connect"* ]]
}

@test "auth failure message includes optional detail" {
    local output
    output=$(baish_print_auth_failure "copilot" "Token has expired" 2>&1)
    [[ "${output}" == *"Token has expired"* ]]
}

@test "auth failure output goes to stderr" {
    local stdout_output stderr_output
    stdout_output=$(baish_print_auth_failure "mock" 2>/dev/null) || true
    stderr_output=$(baish_print_auth_failure "mock" 2>&1 1>/dev/null) || true
    [[ -z "${stdout_output}" ]]
    [[ -n "${stderr_output}" ]]
}

@test "baish_debug output goes to stderr" {
    BAISH_DEBUG=1
    local stdout_output stderr_output
    stdout_output=$(baish_debug "test" 2>/dev/null)
    stderr_output=$(baish_debug "test" 2>&1 1>/dev/null)
    [[ -z "${stdout_output}" ]]
    [[ -n "${stderr_output}" ]]
}

# ============================================================
# Provider error handling
# ============================================================

@test "baish_handle_provider_error returns 1 for context overflow" {
    local stderr="CONTEXT_OVERFLOW"
    local result=0
    baish_handle_provider_error "${stderr}" "mock" 2>/dev/null || result=$?
    [[ "${result}" -eq 1 ]]
}

@test "baish_handle_provider_error returns 1 for auth failure" {
    local stderr="AUTH_FAILURE"
    local result=0
    baish_handle_provider_error "${stderr}" "mock" 2>/dev/null || result=$?
    [[ "${result}" -eq 1 ]]
}

@test "baish_handle_provider_error returns 1 for generic error" {
    local stderr="Something unexpected happened"
    local result=0
    baish_handle_provider_error "${stderr}" "mock" 2>/dev/null || result=$?
    [[ "${result}" -eq 1 ]]
}

# ============================================================
# Mock provider error simulation
# ============================================================

@test "mock provider returns success by default" {
    BAISH_CURRENT_MODEL="mock-model"
    local result
    result=$(provider_mock_chat '[]' '[]' 2>/dev/null)
    local exit_code=$?
    [[ "${exit_code}" -eq 0 ]]
    [[ "${result}" == *"I am the mock provider"* ]]
}

@test "mock provider returns forced exit code" {
    BAISH_MOCK_EXIT_CODE=1
    BAISH_MOCK_STDERR=""
    BAISH_CURRENT_MODEL="mock-model"
    local exit_code=0
    provider_mock_chat '[]' '[]' 2>/dev/null || exit_code=$?
    [[ "${exit_code}" -eq 1 ]]
}

@test "mock provider writes stderr content when simulating errors" {
    BAISH_MOCK_EXIT_CODE=1
    BAISH_MOCK_STDERR="CONTEXT_OVERFLOW"
    BAISH_CURRENT_MODEL="mock-model"
    local stderr_output
    stderr_output=$(provider_mock_chat '[]' '[]' 2>&1 1>/dev/null) || true
    [[ "${stderr_output}" == *"CONTEXT_OVERFLOW"* ]]
}

@test "mock provider can simulate auth failure via stderr" {
    BAISH_MOCK_EXIT_CODE=1
    BAISH_MOCK_STDERR="AUTH_FAILURE"
    BAISH_CURRENT_MODEL="mock-model"
    local stderr_output
    stderr_output=$(provider_mock_chat '[]' '[]' 2>&1 1>/dev/null) || true
    [[ "${stderr_output}" == *"AUTH_FAILURE"* ]]
}

@test "mock provider does not write stderr on success" {
    BAISH_MOCK_EXIT_CODE=0
    BAISH_MOCK_STDERR="should not appear"
    BAISH_CURRENT_MODEL="mock-model"
    local stderr_output
    stderr_output=$(provider_mock_chat '[]' '[]' 2>&1 1>/dev/null)
    [[ -z "${stderr_output}" ]]
}

# ============================================================
# Environment-based auth detection
# ============================================================

@test "copilot detects env auth via GH_TOKEN" {
    export GH_TOKEN="gho_test123"
    unset GITHUB_TOKEN 2>/dev/null || true
    provider_copilot_has_env_auth
    local exit_code=$?
    [[ "${exit_code}" -eq 0 ]]
}

@test "copilot detects env auth via GITHUB_TOKEN" {
    unset GH_TOKEN 2>/dev/null || true
    export GITHUB_TOKEN="gho_test456"
    provider_copilot_has_env_auth
    local exit_code=$?
    [[ "${exit_code}" -eq 0 ]]
}

@test "copilot returns 1 when no env auth" {
    unset GH_TOKEN 2>/dev/null || true
    unset GITHUB_TOKEN 2>/dev/null || true
    local exit_code=0
    provider_copilot_has_env_auth || exit_code=$?
    [[ "${exit_code}" -eq 1 ]]
}

@test "kilo detects env auth via KILO_API_KEY" {
    export KILO_API_KEY="sk-test-key"
    provider_kilo_has_env_auth
    local exit_code=$?
    [[ "${exit_code}" -eq 0 ]]
}

@test "kilo returns 1 when no env auth" {
    unset KILO_API_KEY 2>/dev/null || true
    local exit_code=0
    provider_kilo_has_env_auth || exit_code=$?
    [[ "${exit_code}" -eq 1 ]]
}

@test "mock always reports env auth available" {
    provider_mock_has_env_auth
    local exit_code=$?
    [[ "${exit_code}" -eq 0 ]]
}

# ============================================================
# Debug logging
# ============================================================

@test "baish_debug outputs nothing when BAISH_DEBUG=0" {
    BAISH_DEBUG=0
    local output
    output=$(baish_debug "test message" 2>&1)
    [[ -z "${output}" ]]
}

@test "baish_debug outputs to stderr when BAISH_DEBUG=1" {
    BAISH_DEBUG=1
    local output
    output=$(baish_debug "test message" 2>&1)
    [[ "${output}" == *"[DEBUG]"* ]]
    [[ "${output}" == *"test message"* ]]
}

@test "baish_debug_http includes provider method and url" {
    BAISH_DEBUG=1
    local output
    output=$(baish_debug_http "kilo" "POST" "https://example.com/api" "" "test" 2>&1)
    [[ "${output}" == *"[DEBUG]"* ]]
    [[ "${output}" == *"[kilo]"* ]]
    [[ "${output}" == *"POST"* ]]
    [[ "${output}" == *"https://example.com/api"* ]]
    [[ "${output}" == *"(test)"* ]]
}

@test "baish_debug_http includes status code when provided" {
    BAISH_DEBUG=1
    local output
    output=$(baish_debug_http "copilot" "GET" "/models" "200" "" 2>&1)
    [[ "${output}" == *"200"* ]]
}

@test "baish_debug_tool includes tool name" {
    BAISH_DEBUG=1
    local output
    output=$(baish_debug_tool "read" "path=test.sh" "success" 2>&1)
    [[ "${output}" == *"[DEBUG]"* ]]
    [[ "${output}" == *"Tool: read"* ]]
    [[ "${output}" == *"path=test.sh"* ]]
    [[ "${output}" == *"success"* ]]
}

@test "baish_debug_state includes from and to states" {
    BAISH_DEBUG=1
    local output
    output=$(baish_debug_state "idle" "processing" "user message" 2>&1)
    [[ "${output}" == *"[DEBUG]"* ]]
    [[ "${output}" == *"idle"* ]]
    [[ "${output}" == *"processing"* ]]
    [[ "${output}" == *"user message"* ]]
}

# ============================================================
# Integration: run-loop with mock provider
# ============================================================

@test "run-loop captures stderr from mock provider error" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_EXIT_CODE=1
    BAISH_MOCK_STDERR="CONTEXT_OVERFLOW"
    local messages='[{"role":"user","content":"hello"}]'
    local tools="[]"
    local request
    request=$(jq -n --argjson msg "${messages}" --argjson t "${tools}" '{"messages":$msg,"tools":$t}')
    > "${BAISH_CHAT_STDERR_FILE}"
    local response
    response=$(baish_agent_provider_chat_capture "${request}" 2>/dev/null) || true
    local stderr_content
    stderr_content=$(cat "${BAISH_CHAT_STDERR_FILE}" 2>/dev/null || echo "")
    [[ "${stderr_content}" == *"CONTEXT_OVERFLOW"* ]]
}

@test "run-loop handles context overflow and breaks the loop" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_EXIT_CODE=1
    BAISH_MOCK_STDERR="CONTEXT_OVERFLOW"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_SESSION_TOTAL_TOOL_CALLS=0
    local output
    output=$(baish_agent_run_user_message "test message" 2>&1) || true
    [[ "${output}" == *"/new"* ]] || [[ "${output}" == *"context"* ]]
}

@test "run-loop handles auth failure and breaks the loop" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_EXIT_CODE=1
    BAISH_MOCK_STDERR="AUTH_FAILURE"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_SESSION_TOTAL_TOOL_CALLS=0
    local output
    output=$(baish_agent_run_user_message "test message" 2>&1) || true
    [[ "${output}" == *"/connect"* ]] || [[ "${output}" == *"Authentication"* ]]
}

@test "run-loop succeeds with mock provider on normal response" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="Hello from mock"
    BAISH_MOCK_EXIT_CODE=0
    BAISH_MOCK_STDERR=""
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_SESSION_TOTAL_TOOL_CALLS=0
    local output
    output=$(baish_agent_run_user_message "test message" 2>&1) || true
    [[ "${output}" == *"Hello from mock"* ]]
}
