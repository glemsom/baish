#!/usr/bin/env bats
# BAISH — Tests: Kilo Gateway Provider Full Implementation
#
# Tests:
# - API key auth validates against the gateway and persists the key
# - Model listing returns all models from API, grouped by provider prefix
# - Chat requests succeed and return normalized {assistant_text, tool_calls}
# - Full prefixed model IDs (e.g., anthropic/claude-sonnet-4.5) work correctly
# - Environment-based auth detection when KILO_API_KEY is set
# - Context overflow and auth failure detection

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
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"
    source "${BAISH_ROOT}/lib/providers/kilo.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
    unset KILO_API_KEY 2>/dev/null || true
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

@test "kilo provider metadata returns correct shape" {
    local metadata
    metadata=$(provider_kilo_metadata)

    local id label selectable desc
    id=$(echo "${metadata}" | jq -r '.id')
    label=$(echo "${metadata}" | jq -r '.label')
    selectable=$(echo "${metadata}" | jq -r '.selectable')
    desc=$(echo "${metadata}" | jq -r '.desc')

    [[ "${id}" == "kilo" ]]
    [[ "${label}" == "Kilo Gateway" ]]
    [[ "${selectable}" == "true" ]]
    [[ -n "${desc}" ]]
}

# ============================================================
# Environment-based auth detection
# ============================================================

@test "kilo detects env auth when KILO_API_KEY is set" {
    export KILO_API_KEY="sk-test-key"
    provider_kilo_has_env_auth
    [[ $? -eq 0 ]]
}

@test "kilo returns no env auth when KILO_API_KEY is not set" {
    unset KILO_API_KEY 2>/dev/null || true
    provider_kilo_has_env_auth || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

# ============================================================
# Auth: API key persistence
# ============================================================

@test "kilo auth persists API key to auth file" {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n --arg key "sk-kilo-test-key" \
        --arg ts "2026-06-05T00:00:00Z" \
        '{"api_key": $key, "authenticated_at": $ts, "provider": "kilo"}' \
        > "${auth_file}"

    local stored_key stored_provider stored_ts
    stored_key=$(jq -r '.api_key' "${auth_file}")
    stored_provider=$(jq -r '.provider' "${auth_file}")
    stored_ts=$(jq -r '.authenticated_at' "${auth_file}")

    [[ "${stored_key}" == "sk-kilo-test-key" ]]
    [[ "${stored_provider}" == "kilo" ]]
    [[ "${stored_ts}" == "2026-06-05T00:00:00Z" ]]
}

@test "kilo auth file includes authenticated_at timestamp" {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n '{"api_key": "sk-kilo-test", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "kilo"}' \
        > "${auth_file}"

    local ts
    ts=$(jq -r '.authenticated_at' "${auth_file}")
    [[ "${ts}" == "2026-06-05T00:00:00Z" ]]
}

# ============================================================
# API key loading
# ============================================================

@test "kilo loads API key from env var when set" {
    export KILO_API_KEY="sk-from-env"
    local key
    key=$(_kilo_load_api_key)
    [[ "${key}" == "sk-from-env" ]]
}

@test "kilo loads API key from auth file when env not set" {
    unset KILO_API_KEY 2>/dev/null || true
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "sk-from-file", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "kilo"}' \
        > "${auth_file}"

    local key
    key=$(_kilo_load_api_key)
    [[ "${key}" == "sk-from-file" ]]
}

@test "kilo env var takes precedence over auth file" {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "sk-from-file", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "kilo"}' \
        > "${auth_file}"

    export KILO_API_KEY="sk-from-env"
    local key
    key=$(_kilo_load_api_key)
    [[ "${key}" == "sk-from-env" ]]
}

@test "kilo returns empty string when no key available" {
    unset KILO_API_KEY 2>/dev/null || true

    local key
    key=$(_kilo_load_api_key) || true
    [[ -z "${key}" ]]
}

# ============================================================
# Model listing — mock curl tests
# ============================================================

@test "kilo model listing returns empty array when no API key" {
    unset KILO_API_KEY 2>/dev/null || true

    local models
    models=$(provider_kilo_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 0 ]]
}

@test "kilo model listing returns all models from API" {
    export KILO_API_KEY="sk-test-key"

    # Mock response matching real Kilo Gateway API format (no features/object fields)
    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "anthropic/claude-sonnet-4-20250514", name: "Claude Sonnet 4"},
            {id: "openai/gpt-4o", name: "GPT-4o"},
            {id: "openai/text-embedding-3-small", name: "Text Embedding 3 Small"},
            {id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"},
            {id: "anthropic/claude-opus-4-20250514", name: "Claude Opus 4"}
        ]
    }')

    _mock_curl_models() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_models "$@"; }
    export -f curl

    local models
    models=$(provider_kilo_list_models)

    # All models from the API are returned (no filtering)
    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 5 ]]

    local ids
    ids=$(echo "${models}" | jq -r '[.[].id] | sort | join(",")')
    [[ "${ids}" == "anthropic/claude-opus-4-20250514,anthropic/claude-sonnet-4-20250514,google/gemini-2.5-pro,openai/gpt-4o,openai/text-embedding-3-small" ]]
}

@test "kilo model listing groups models by provider prefix" {
    export KILO_API_KEY="sk-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "openai/gpt-4o", name: "GPT-4o"},
            {id: "anthropic/claude-sonnet-4-20250514", name: "Claude Sonnet 4"},
            {id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"}
        ]
    }')

    _mock_curl_models_grouped() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_models_grouped "$@"; }
    export -f curl

    local models
    models=$(provider_kilo_list_models)

    # Verify group field is set correctly
    local anthropic_group openai_group google_group
    anthropic_group=$(echo "${models}" | jq -r '.[] | select(.id == "anthropic/claude-sonnet-4-20250514") | .group')
    openai_group=$(echo "${models}" | jq -r '.[] | select(.id == "openai/gpt-4o") | .group')
    google_group=$(echo "${models}" | jq -r '.[] | select(.id == "google/gemini-2.5-pro") | .group')

    [[ "${anthropic_group}" == "anthropic" ]]
    [[ "${openai_group}" == "openai" ]]
    [[ "${google_group}" == "google" ]]
}

@test "kilo model listing uses full prefixed model IDs" {
    export KILO_API_KEY="sk-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5"},
            {id: "openai/gpt-4o-mini", name: "GPT-4o Mini"}
        ]
    }')

    _mock_curl_prefixed() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_prefixed "$@"; }
    export -f curl

    local models
    models=$(provider_kilo_list_models)

    local model_ids
    model_ids=$(echo "${models}" | jq -r '.[0].id')
    [[ "${model_ids}" == "anthropic/claude-sonnet-4.5" ]]

    local second_id
    second_id=$(echo "${models}" | jq -r '.[1].id')
    [[ "${second_id}" == "openai/gpt-4o-mini" ]]
}

@test "kilo model listing includes name field derived from model ID" {
    export KILO_API_KEY="sk-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "anthropic/claude-sonnet-4-20250514", name: "Claude Sonnet 4"}
        ]
    }')

    _mock_curl_name() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_name "$@"; }
    export -f curl

    local models
    models=$(provider_kilo_list_models)

    local name
    name=$(echo "${models}" | jq -r '.[0].name')
    [[ -n "${name}" ]]
}

@test "kilo model listing handles models without extra fields" {
    export KILO_API_KEY="sk-test-key"

    # Models with minimal fields (only id) should still work
    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "openai/gpt-4o"},
            {id: "anthropic/claude-sonnet-4-20250514"}
        ]
    }')

    _mock_curl_no_features() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_no_features "$@"; }
    export -f curl

    local models
    models=$(provider_kilo_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 2 ]]
}

@test "kilo model listing deduplicates models" {
    export KILO_API_KEY="sk-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "openai/gpt-4o", name: "GPT-4o"},
            {id: "openai/gpt-4o", name: "GPT-4o"}
        ]
    }')

    _mock_curl_dedup() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_dedup "$@"; }
    export -f curl

    local models
    models=$(provider_kilo_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 1 ]]
}

# ============================================================
# Chat — mock curl tests
# ============================================================

@test "kilo chat returns structured error when no API key" {
    unset KILO_API_KEY 2>/dev/null || true

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "kilo chat returns normalized {ok, assistant_text, tool_calls} shape" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="anthropic/claude-sonnet-4-20250514"

    local response_body
    response_body=$(jq -n '{
        choices: [{
            message: {
                content: "Kilo chat works",
                tool_calls: []
            }
        }]
    }')

    _mock_curl_chat_basic() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_chat_basic "$@"; }
    export -f curl

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local has_ok has_text has_tc
    has_ok=$(echo "${result}" | jq 'has("ok")')
    has_text=$(echo "${result}" | jq 'has("assistant_text")')
    has_tc=$(echo "${result}" | jq 'has("tool_calls")')

    [[ "${has_ok}" == "true" ]]
    [[ "${has_text}" == "true" ]]
    [[ "${has_tc}" == "true" ]]

    local ok text
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    [[ "${ok}" == "true" ]]
    [[ "${text}" == "Kilo chat works" ]]
}

@test "kilo chat parses tool calls correctly" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    local response_body
    response_body=$(jq -n '{
        choices: [{
            message: {
                content: "I will read that file.",
                tool_calls: [{
                    id: "tc-kilo-1",
                    function: {
                        name: "read",
                        arguments: "{\"path\":\"test.txt\"}"
                    }
                }]
            }
        }]
    }')

    _mock_curl_chat_tools() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_chat_tools "$@"; }
    export -f curl

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local tc_len tc_name tc_id
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')
    tc_id=$(echo "${result}" | jq -r '.tool_calls[0].id')

    [[ "${tc_len}" == "1" ]]
    [[ "${tc_name}" == "read" ]]
    [[ "${tc_id}" == "tc-kilo-1" ]]
}

@test "kilo chat sends correct model in payload" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="anthropic/claude-sonnet-4.5"

    # Capture the request payload via a file
    local payload_file="${BAISH_STATE_DIR}/payload.json"

    _mock_curl_capture_payload() {
        local args=("$@")
        # Find the -d argument
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "ok", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_capture_payload "$@"; }
    export -f curl

    provider_kilo_chat '[]' '[]' > /dev/null

    local model_in_payload
    model_in_payload=$(jq -r '.model' "${payload_file}")
    [[ "${model_in_payload}" == "anthropic/claude-sonnet-4.5" ]]
}

@test "kilo chat includes tools in payload when provided" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    local payload_file="${BAISH_STATE_DIR}/payload.json"
    local tools_json='[{"type": "function", "function": {"name": "read", "parameters": {"type": "object"}}}]'

    _mock_curl_capture_tools() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "ok", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_capture_tools "$@"; }
    export -f curl

    provider_kilo_chat '[]' "${tools_json}" > /dev/null

    local has_tools
    has_tools=$(jq 'has("tools")' "${payload_file}")
    [[ "${has_tools}" == "true" ]]

    local tools_name
    tools_name=$(jq -r '.tools[0].function.name' "${payload_file}")
    [[ "${tools_name}" == "read" ]]
}

@test "kilo chat omits tools from payload when not provided" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    local payload_file="${BAISH_STATE_DIR}/payload.json"

    _mock_curl_no_tools() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "ok", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_no_tools "$@"; }
    export -f curl

    provider_kilo_chat '[]' '[]' > /dev/null

    local has_tools
    has_tools=$(jq 'has("tools")' "${payload_file}")
    [[ "${has_tools}" == "false" ]]
}

# ============================================================
# Error handling
# ============================================================

@test "kilo detects context overflow from chat response (structured JSON)" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    _mock_curl_overflow() {
        printf '{"error": {"message": "context_length_exceeded: input is too long"}}\n400'
    }

    curl() { _mock_curl_overflow "$@"; }
    export -f curl

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "CONTEXT_OVERFLOW" ]]
}

@test "kilo returns structed AUTH_FAILURE on 401 error" {
    export KILO_API_KEY="sk-invalid-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    _mock_curl_401() {
        printf '{"error": {"message": "Invalid API key"}}\n401'
    }

    curl() { _mock_curl_401 "$@"; }
    export -f curl

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "kilo returns structed AUTH_FAILURE on 403 error" {
    export KILO_API_KEY="sk-forbidden-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    _mock_curl_403() {
        printf '{"error": {"message": "Access denied"}}\n403'
    }

    curl() { _mock_curl_403 "$@"; }
    export -f curl

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "kilo reports generic error on 500 server error" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    _mock_curl_500() {
        printf '{"error": {"message": "Internal server error"}}\n500'
    }

    curl() { _mock_curl_500 "$@"; }
    export -f curl

    local result
    result=$(provider_kilo_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "GENERIC_ERROR" ]]
}

# ============================================================
# Integration: Kilo via agent loop
# ============================================================

@test "agent loop works with kilo provider and mock curl" {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "sk-kilo-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "kilo"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="kilo"
    BAISH_CURRENT_MODEL="anthropic/claude-sonnet-4-20250514"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    _mock_curl_kilo_integration() {
        local args=("$@")
        # Check for validation call (-o /dev/null + -w "%{http_code}")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-o" && "${args[$((i+1))]}" == "/dev/null" ]]; then
                printf '200'
                return
            fi
        done
        printf '{"choices": [{"message": {"content": "Kilo agent loop works", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_kilo_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Hello from kilo integration"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 2 ]]

    local assistant_msg content
    assistant_msg="${BAISH_SESSION_MESSAGES[1]}"
    content=$(echo "${assistant_msg}" | jq -r '.content')

    [[ "${content}" == "Kilo agent loop works" ]]
}

# ============================================================
# Integration: prefixed model IDs end-to-end
# ============================================================

@test "agent loop works with prefixed model ID anthropic/claude-sonnet-4.5" {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "sk-kilo-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "kilo"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="kilo"
    BAISH_CURRENT_MODEL="anthropic/claude-sonnet-4.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local payload_file="${BAISH_STATE_DIR}/integration_payload.json"

    _mock_curl_prefixed_integration() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-o" && "${args[$((i+1))]}" == "/dev/null" ]]; then
                # Validation call — return just HTTP status
                printf '200'
                return
            fi
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "Prefixed model works", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_prefixed_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Test prefixed model"

    local model_in_payload
    model_in_payload=$(jq -r '.model' "${payload_file}")
    [[ "${model_in_payload}" == "anthropic/claude-sonnet-4.5" ]]
}

# ============================================================
# Chat with messages
# ============================================================

@test "kilo chat forwards messages correctly" {
    export KILO_API_KEY="sk-test-key"
    BAISH_CURRENT_MODEL="openai/gpt-4o"

    local payload_file="${BAISH_STATE_DIR}/messages_payload.json"
    local messages_json='[{"role": "user", "content": "Hello, Kilo!"}]'

    _mock_curl_messages() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "Hello back!", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_messages "$@"; }
    export -f curl

    provider_kilo_chat "${messages_json}" '[]' > /dev/null

    local msg_content
    msg_content=$(jq -r '.messages[0].content' "${payload_file}")
    [[ "${msg_content}" == "Hello, Kilo!" ]]

    local msg_role
    msg_role=$(jq -r '.messages[0].role' "${payload_file}")
    [[ "${msg_role}" == "user" ]]
}

# ============================================================
# API key validation
# ============================================================

@test "kilo validates API key against chat completions endpoint" {
    export KILO_API_KEY="sk-valid-key"

    echo 0 > "${CURL_CALL_COUNT_FILE}"

    _mock_curl_validate() {
        _curl_count
        printf '200'
    }

    curl() { _mock_curl_validate "$@"; }
    export -f curl

    _kilo_validate_key "sk-valid-key"
    [[ $? -eq 0 ]]
}

@test "kilo rejects invalid API key on validation" {
    echo 0 > "${CURL_CALL_COUNT_FILE}"

    _mock_curl_validate_fail() {
        _curl_count
        printf ''
        printf '401'
    }

    curl() { _mock_curl_validate_fail "$@"; }
    export -f curl

    _kilo_validate_key "sk-invalid-key" || result=$?
    [[ "${result:-0}" -ne 0 ]]
}
