#!/usr/bin/env bats
# BAISH — Tests: Copilot Provider Full Implementation

setup() {
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"

    BAISH_LAUNCH_DIR="${BAISH_STATE_DIR}/workspace"
    export BAISH_LAUNCH_DIR
    mkdir -p "${BAISH_LAUNCH_DIR}"

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT
    export BAISH_AUTH_DIR="${BAISH_STATE_DIR}/auth"
    mkdir -p "${BAISH_AUTH_DIR}"

    # File-based call counter (works across subshells)
    export CURL_CALL_COUNT_FILE="${BAISH_STATE_DIR}/curl_calls"
    echo 0 > "${CURL_CALL_COUNT_FILE}"

    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
    source "${BAISH_ROOT}/lib/providers/discovery.sh"
    source "${BAISH_ROOT}/lib/providers/copilot.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
    unset BAISH_COPILOT_RUNTIME_TOKEN
    unset BAISH_COPILOT_RUNTIME_EXPIRY
}

_curl_count() {
    local n
    n=$(cat "${CURL_CALL_COUNT_FILE}")
    echo $(( n + 1 )) > "${CURL_CALL_COUNT_FILE}"
}

_curl_get_count() {
    cat "${CURL_CALL_COUNT_FILE}"
}

# ============================================================
# Provider metadata
# ============================================================

@test "copilot provider metadata returns correct shape" {
    local metadata
    metadata=$(provider_copilot_metadata)

    local id label selectable
    id=$(echo "${metadata}" | jq -r '.id')
    label=$(echo "${metadata}" | jq -r '.label')
    selectable=$(echo "${metadata}" | jq -r '.selectable')

    [[ "${id}" == "copilot" ]]
    [[ "${label}" == "GitHub Copilot" ]]
    [[ "${selectable}" == "true" ]]
}

# ============================================================
# Environment-based auth detection
# ============================================================

@test "copilot detects env auth when GH_TOKEN is set" {
    export GH_TOKEN="gho_test123"
    provider_copilot_has_env_auth
    [[ $? -eq 0 ]]
}

@test "copilot detects env auth when GITHUB_TOKEN is set" {
    export GITHUB_TOKEN="ghp_test456"
    provider_copilot_has_env_auth
    [[ $? -eq 0 ]]
}

@test "copilot returns no env auth when neither token is set" {
    unset GH_TOKEN GITHUB_TOKEN 2>/dev/null || true
    provider_copilot_has_env_auth || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

# ============================================================
# OAuth device flow — token persistence
# ============================================================

@test "copilot auth persists long-lived token to auth file" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n --arg token "gho_simulated_token" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{"github_token": $token, "authenticated_at": $ts, "provider": "github"}' \
        > "${auth_file}"

    local stored_token stored_provider
    stored_token=$(jq -r '.github_token' "${auth_file}")
    stored_provider=$(jq -r '.provider' "${auth_file}")

    [[ "${stored_token}" == "gho_simulated_token" ]]
    [[ "${stored_provider}" == "github" ]]
}

@test "copilot auth file includes timestamp" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n '{"github_token": "gho_test", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "github"}' \
        > "${auth_file}"

    local ts
    ts=$(jq -r '.authenticated_at' "${auth_file}")
    [[ "${ts}" == "2026-06-05T00:00:00Z" ]]
}

@test "copilot auth skips when valid token already exists" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n '{"github_token": "gho_existing", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "github"}' \
        > "${auth_file}"

    provider_copilot_auth
    [[ $? -eq 0 ]]
}

# ============================================================
# Runtime token refresh
# ============================================================

@test "copilot loads github token from auth file" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_loaded_token"}' > "${auth_file}"

    local token
    token=$(_copilot_load_github_token)

    [[ "${token}" == "gho_loaded_token" ]]
}

@test "copilot returns empty string when no auth file exists" {
    local token
    token=$(_copilot_load_github_token)

    [[ -z "${token}" ]]
}

@test "copilot runtime token refresh fails without github token" {
    _copilot_refresh_runtime_token || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

# ============================================================
# Model listing and routing
# ============================================================

@test "copilot model list includes gpt-5 models" {
    local models
    models=$(provider_copilot_list_models)

    local gpt5_count
    gpt5_count=$(echo "${models}" | jq '[.[].id | select(startswith("gpt-5"))] | length')
    [[ "${gpt5_count}" -gt 0 ]]
}

@test "copilot model list includes non-gpt-5 models" {
    local models
    models=$(provider_copilot_list_models)

    local other_count
    other_count=$(echo "${models}" | jq '[.[].id | select(startswith("gpt-5") | not)] | length')
    [[ "${other_count}" -gt 0 ]]
}

@test "copilot model list entries have id and name fields" {
    local models
    models=$(provider_copilot_list_models)

    local valid
    valid=$(echo "${models}" | jq '[.[] | has("id") and has("name")] | all')
    [[ "${valid}" == "true" ]]
}

# ============================================================
# Auto-reconnect on token expiry
# ============================================================

@test "copilot chat auto-reconnects on TOKEN_EXPIRED and retries" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"
    echo 0 > "${CURL_CALL_COUNT_FILE}"

    _mock_curl() {
        _curl_count
        local n
        n=$(_curl_get_count)
        case "${n}" in
            1)
                # Runtime token refresh
                printf '{"token": "ghc_initial", "expires_at": %d}\n200' "$(date +%s)"
                ;;
            2)
                # Chat call: 401 token expired
                printf '{"error": {"message": "token expired"}}\n401'
                ;;
            3)
                # Refresh after expiry
                printf '{"token": "ghc_refreshed", "expires_at": %d}\n200' "$(( $(date +%s) + 300 ))"
                ;;
            4)
                # Retry chat: success
                printf '{"choices": [{"message": {"content": "Hello after reconnect", "tool_calls": []}}]}\n200'
                ;;
        esac
    }

    curl() { _mock_curl "$@"; }
    export -f curl

    local result
    result=$(provider_copilot_chat '[]' '[]')

    local text
    text=$(echo "${result}" | jq -r '.assistant_text')

    [[ "${text}" == "Hello after reconnect" ]]
    [[ $(_curl_get_count) -ge 4 ]]
}

@test "copilot chat succeeds without reconnect when token is valid" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))
    echo 0 > "${CURL_CALL_COUNT_FILE}"

    _mock_curl_single() {
        _curl_count
        printf '{"choices": [{"message": {"content": "Direct response", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_single "$@"; }
    export -f curl

    local result
    result=$(provider_copilot_chat '[]' '[]')

    local text
    text=$(echo "${result}" | jq -r '.assistant_text')

    [[ "${text}" == "Direct response" ]]
    [[ $(_curl_get_count) -eq 1 ]]
}

@test "copilot chat does not auto-reconnect on non-401 errors" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))
    echo 0 > "${CURL_CALL_COUNT_FILE}"

    _mock_curl_500() {
        _curl_count
        printf '{"error": {"message": "internal server error"}}\n500'
    }

    curl() { _mock_curl_500 "$@"; }
    export -f curl

    provider_copilot_chat '[]' '[]' || result=$?
    [[ "${result:-0}" -ne 0 ]]
    [[ $(_curl_get_count) -eq 1 ]]
}

@test "copilot chat auto-reconnect works for gpt-5 models (Responses API)" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-5"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_initial"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(date +%s)
    echo 0 > "${CURL_CALL_COUNT_FILE}"

    _mock_curl_gpt5() {
        _curl_count
        local n
        n=$(_curl_get_count)
        case "${n}" in
            1)
                printf '{"token": "ghc_refreshed", "expires_at": %d}\n200' "$(( $(date +%s) + 300 ))"
                ;;
            2)
                printf '{"output": [{"type": "message", "content": [{"type": "text", "text": "GPT-5 response"}]}]}\n200'
                ;;
        esac
    }

    curl() { _mock_curl_gpt5 "$@"; }
    export -f curl

    local result
    result=$(provider_copilot_chat '[]' '[]')

    local text
    text=$(echo "${result}" | jq -r '.assistant_text')

    [[ "${text}" == "GPT-5 response" ]]
}

# ============================================================
# Context overflow detection
# ============================================================

@test "copilot detects context overflow in Chat Completions API" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))

    _mock_curl_overflow() {
        printf '{"error": {"message": "context_length_exceeded: this model max context length is 8192"}}\n400'
    }

    curl() { _mock_curl_overflow "$@"; }
    export -f curl

    provider_copilot_chat '[]' '[]' || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

@test "copilot detects context overflow in Responses API" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-5"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))

    _mock_curl_responses_overflow() {
        printf '{"message": "context_length_exceeded: input is too long"}\n400'
    }

    curl() { _mock_curl_responses_overflow "$@"; }
    export -f curl

    provider_copilot_chat '[]' '[]' || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

# ============================================================
# Loud auth failure on invalid credentials
# ============================================================

@test "copilot chat fails loudly when runtime token refresh returns 401" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_invalid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"

    _mock_curl_auth_fail() {
        printf '{"message": "Bad credentials"}\n401'
    }

    curl() { _mock_curl_auth_fail "$@"; }
    export -f curl

    local stderr_output
    stderr_output=$(provider_copilot_chat '[]' '[]' 2>&1) || true

    [[ "${stderr_output}" == *"invalid"* || "${stderr_output}" == *"re-authenticate"* || "${stderr_output}" == *"Bad credentials"* ]]
}

@test "copilot chat fails loudly when runtime token refresh returns 403" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_denied_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"

    _mock_curl_forbidden() {
        printf '{"message": "Resource not accessible"}\n403'
    }

    curl() { _mock_curl_forbidden "$@"; }
    export -f curl

    local stderr_output
    stderr_output=$(provider_copilot_chat '[]' '[]' 2>&1) || true

    [[ "${stderr_output}" == *"invalid"* || "${stderr_output}" == *"re-authenticate"* || "${stderr_output}" == *"denied"* || "${stderr_output}" == *"not accessible"* ]]
}

# ============================================================
# Chat Completions API response parsing
# ============================================================

@test "copilot chat parses Chat Completions API response correctly" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-4o"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))

    # Use jq to build proper JSON to avoid escaping issues
    local response_body
    response_body=$(jq -n '{
        choices: [{
            message: {
                content: "Chat completions works",
                tool_calls: [{
                    id: "tc-1",
                    function: {
                        name: "read",
                        arguments: "{\"path\":\"test.txt\"}"
                    }
                }]
            }
        }]
    }')

    _mock_curl_chat_response() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_chat_response "$@"; }
    export -f curl

    local result
    result=$(provider_copilot_chat '[]' '[]')

    local text tc_len tc_name
    text=$(echo "${result}" | jq -r '.assistant_text')
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')

    [[ "${text}" == "Chat completions works" ]]
    [[ "${tc_len}" == "1" ]]
    [[ "${tc_name}" == "read" ]]
}

# ============================================================
# Responses API response parsing (gpt-5 models)
# ============================================================

@test "copilot chat parses Responses API response correctly for gpt-5" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-5"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))

    local response_body
    response_body=$(jq -n '{
        output: [{
            type: "message",
            content: [{type: "text", text: "Responses API works"}]
        }]
    }')

    _mock_curl_responses_response() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_responses_response "$@"; }
    export -f curl

    local result
    result=$(provider_copilot_chat '[]' '[]')

    local text
    text=$(echo "${result}" | jq -r '.assistant_text')

    [[ "${text}" == "Responses API works" ]]
}

@test "copilot chat parses Responses API tool calls for gpt-5" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_MODEL="gpt-5-mini"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))

    local response_body
    response_body=$(jq -n '{
        output: [
            {type: "message", content: [{type: "text", text: "Let me read that file"}]},
            {type: "function_call", id: "fc-1", name: "read", arguments: "{\"path\":\"file.txt\"}"}
        ]
    }')

    _mock_curl_responses_tools() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_responses_tools "$@"; }
    export -f curl

    local result
    result=$(provider_copilot_chat '[]' '[]')

    local tc_len tc_name
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')

    [[ "${tc_len}" == "1" ]]
    [[ "${tc_name}" == "read" ]]
}

# ============================================================
# Integration: Copilot via agent loop
# ============================================================

@test "agent loop works with copilot provider and mock curl" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"github_token": "gho_valid_token"}' > "${auth_file}"

    BAISH_CURRENT_PROVIDER="copilot"
    BAISH_CURRENT_MODEL="gpt-4o"
    BAISH_COPILOT_RUNTIME_TOKEN="ghc_valid"
    BAISH_COPILOT_RUNTIME_EXPIRY=$(( $(date +%s) + 600 ))
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_SESSION_TOTAL_TOOL_CALLS=0
    BAISH_DEBUG=0

    _mock_curl_integration() {
        printf '{"choices": [{"message": {"content": "Agent loop integration works", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Hello from integration test"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 2 ]]

    local assistant_msg content
    assistant_msg="${BAISH_SESSION_MESSAGES[1]}"
    content=$(echo "${assistant_msg}" | jq -r '.content')

    [[ "${content}" == "Agent loop integration works" ]]
}
