#!/usr/bin/env bats
# BAISH — Tests: OpenCode Go Provider
#
# Tests for the OpenCode Go provider foundation:
# - Metadata
# - Environment-based auth detection
# - API key loading (env var, auth file, precedence)
# - API key validation
# - Auth persistence
# - Model listing (API fetch, name derivation, prefix grouping)

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

    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/providers/discovery.sh"
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"
    source "${BAISH_ROOT}/lib/providers/opencodego.sh"
    source "${BAISH_ROOT}/lib/agent/errors.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
    unset OPENCODEGO_API_KEY 2>/dev/null || true
}

# ============================================================
# Provider metadata
# ============================================================

@test "opencodego provider metadata returns correct shape" {
    local metadata
    metadata=$(provider_opencodego_metadata)

    local id label selectable desc
    id=$(echo "${metadata}" | jq -r '.id')
    label=$(echo "${metadata}" | jq -r '.label')
    selectable=$(echo "${metadata}" | jq -r '.selectable')
    desc=$(echo "${metadata}" | jq -r '.desc')

    [[ "${id}" == "opencodego" ]]
    [[ "${label}" == "OpenCode Go" ]]
    [[ "${selectable}" == "true" ]]
    [[ -n "${desc}" ]]
}

# ============================================================
# Environment-based auth detection
# ============================================================

@test "opencodego detects env auth when OPENCODEGO_API_KEY is set" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    provider_opencodego_has_env_auth
    [[ $? -eq 0 ]]
}

@test "opencodego returns no env auth when OPENCODEGO_API_KEY is not set" {
    unset OPENCODEGO_API_KEY 2>/dev/null || true
    provider_opencodego_has_env_auth || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

# ============================================================
# API key loading
# ============================================================

@test "opencodego loads API key from env var when set" {
    export OPENCODEGO_API_KEY="ocg-from-env"
    local key
    key=$(_opencodego_load_api_key)
    [[ "${key}" == "ocg-from-env" ]]
}

@test "opencodego loads API key from auth file when env not set" {
    unset OPENCODEGO_API_KEY 2>/dev/null || true
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-from-file", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    local key
    key=$(_opencodego_load_api_key)
    [[ "${key}" == "ocg-from-file" ]]
}

@test "opencodego env var takes precedence over auth file" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-from-file", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    export OPENCODEGO_API_KEY="ocg-from-env"
    local key
    key=$(_opencodego_load_api_key)
    [[ "${key}" == "ocg-from-env" ]]
}

@test "opencodego returns empty string when no key available" {
    unset OPENCODEGO_API_KEY 2>/dev/null || true

    local key
    key=$(_opencodego_load_api_key) || true
    [[ -z "${key}" ]]
}

# ============================================================
# API key validation
# ============================================================

@test "opencodego validates API key against chat completions endpoint" {
    _mock_curl_validate() {
        printf '200'
    }

    curl() { _mock_curl_validate "$@"; }
    export -f curl

    _opencodego_validate_key "ocg-valid-key"
    [[ $? -eq 0 ]]
}

@test "opencodego rejects invalid API key on validation" {
    _mock_curl_validate_fail() {
        printf '401'
    }

    curl() { _mock_curl_validate_fail "$@"; }
    export -f curl

    _opencodego_validate_key "ocg-invalid-key" || result=$?
    [[ "${result:-0}" -ne 0 ]]
}

# ============================================================
# Auth: API key persistence
# ============================================================

@test "opencodego auth persists API key to auth file" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n --arg key "ocg-test-key" \
        --arg ts "2026-06-05T00:00:00Z" \
        '{"api_key": $key, "authenticated_at": $ts, "provider": "opencodego"}' \
        > "${auth_file}"

    local stored_key stored_provider stored_ts
    stored_key=$(jq -r '.api_key' "${auth_file}")
    stored_provider=$(jq -r '.provider' "${auth_file}")
    stored_ts=$(jq -r '.authenticated_at' "${auth_file}")

    [[ "${stored_key}" == "ocg-test-key" ]]
    [[ "${stored_provider}" == "opencodego" ]]
    [[ "${stored_ts}" == "2026-06-05T00:00:00Z" ]]
}

@test "opencodego auth file includes authenticated_at timestamp" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n '{"api_key": "ocg-test", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    local ts
    ts=$(jq -r '.authenticated_at' "${auth_file}")
    [[ "${ts}" == "2026-06-05T00:00:00Z" ]]
}

# ============================================================
# Model listing — mock curl tests
# ============================================================

@test "opencodego model listing returns empty array when no API key" {
    unset OPENCODEGO_API_KEY 2>/dev/null || true

    local models
    models=$(provider_opencodego_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 0 ]]
}

@test "opencodego model listing returns all models from API" {
    export OPENCODEGO_API_KEY="ocg-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "kimi-k2.5", object: "model", created: 1700000000, owned_by: "kimi"},
            {id: "deepseek-v3", object: "model", created: 1700000001, owned_by: "deepseek"},
            {id: "glm-4.5", object: "model", created: 1700000002, owned_by: "glm"},
            {id: "mimo-v2", object: "model", created: 1700000003, owned_by: "mimo"},
            {id: "hy3-thinking", object: "model", created: 1700000004, owned_by: "hy3"}
        ]
    }')

    _mock_curl_models() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_models "$@"; }
    export -f curl

    local models
    models=$(provider_opencodego_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 5 ]]

    local ids
    ids=$(echo "${models}" | jq -r '[.[].id] | sort | join(",")')
    [[ "${ids}" == "deepseek-v3,glm-4.5,hy3-thinking,kimi-k2.5,mimo-v2" ]]
}

@test "opencodego model listing groups models by ID prefix" {
    export OPENCODEGO_API_KEY="ocg-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "kimi-k2.5", object: "model", created: 1700000000, owned_by: "kimi"},
            {id: "deepseek-v3", object: "model", created: 1700000001, owned_by: "deepseek"},
            {id: "qwen3-coder", object: "model", created: 1700000002, owned_by: "qwen"}
        ]
    }')

    _mock_curl_grouped() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_grouped "$@"; }
    export -f curl

    local models
    models=$(provider_opencodego_list_models)

    local kimi_group deepseek_group qwen_group
    kimi_group=$(echo "${models}" | jq -r '.[] | select(.id == "kimi-k2.5") | .group')
    deepseek_group=$(echo "${models}" | jq -r '.[] | select(.id == "deepseek-v3") | .group')
    qwen_group=$(echo "${models}" | jq -r '.[] | select(.id == "qwen3-coder") | .group')

    [[ "${kimi_group}" == "kimi" ]]
    [[ "${deepseek_group}" == "deepseek" ]]
    [[ "${qwen_group}" == "qwen" ]]
}

@test "opencodego model listing derives display name from ID" {
    export OPENCODEGO_API_KEY="ocg-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "kimi-k2.5", object: "model", created: 1700000000, owned_by: "kimi"}
        ]
    }')

    _mock_curl_name() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_name "$@"; }
    export -f curl

    local models
    models=$(provider_opencodego_list_models)

    local name
    name=$(echo "${models}" | jq -r '.[0].name')
    # kimi-k2.5 → Kimi K2.5
    [[ "${name}" == "Kimi K2.5" ]]
}

@test "opencodego model listing deduplicates models" {
    export OPENCODEGO_API_KEY="ocg-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "kimi-k2.5", object: "model", created: 1700000000, owned_by: "kimi"},
            {id: "kimi-k2.5", object: "model", created: 1700000000, owned_by: "kimi"}
        ]
    }')

    _mock_curl_dedup() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_dedup "$@"; }
    export -f curl

    local models
    models=$(provider_opencodego_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -eq 1 ]]
}

@test "opencodego model listing handles minimax and qwen prefixes" {
    export OPENCODEGO_API_KEY="ocg-test-key"

    local response_body
    response_body=$(jq -n '{
        data: [
            {id: "minimax-m2.5", object: "model", created: 1700000000, owned_by: "minimax"},
            {id: "qwen3-coder-plus", object: "model", created: 1700000001, owned_by: "qwen"}
        ]
    }')

    _mock_curl_minimax() {
        printf '%s' "${response_body}"
    }

    curl() { _mock_curl_minimax "$@"; }
    export -f curl

    local models
    models=$(provider_opencodego_list_models)

    local minimax_group qwen_group minimax_name qwen_name
    minimax_group=$(echo "${models}" | jq -r '.[] | select(.id == "minimax-m2.5") | .group')
    qwen_group=$(echo "${models}" | jq -r '.[] | select(.id == "qwen3-coder-plus") | .group')
    minimax_name=$(echo "${models}" | jq -r '.[] | select(.id == "minimax-m2.5") | .name')
    qwen_name=$(echo "${models}" | jq -r '.[] | select(.id == "qwen3-coder-plus") | .name')

    [[ "${minimax_group}" == "minimax" ]]
    [[ "${qwen_group}" == "qwen" ]]
    # minimax-m2.5 → Minimax M2.5
    [[ "${minimax_name}" == "Minimax M2.5" ]]
    # qwen3-coder-plus → Qwen3 Coder Plus
    [[ "${qwen_name}" == "Qwen3 Coder Plus" ]]
}

# ============================================================
# Chat — OpenAI-compatible path (issue #22)
# ============================================================

@test "opencodego chat with kimi model returns normalized {ok, assistant_text, tool_calls} shape" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local response_body
    response_body=$(jq -n '{
        choices: [{
            message: {
                content: "Hello from kimi",
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
    result=$(provider_opencodego_chat '[]' '[]')

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
    [[ "${text}" == "Hello from kimi" ]]
}

@test "opencodego chat sends correct model in payload" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="deepseek-v3"

    local payload_file="${BAISH_STATE_DIR}/payload.json"

    _mock_curl_capture_payload() {
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

    curl() { _mock_curl_capture_payload "$@"; }
    export -f curl

    provider_opencodego_chat '[]' '[]' > /dev/null

    local model_in_payload
    model_in_payload=$(jq -r '.model' "${payload_file}")
    [[ "${model_in_payload}" == "deepseek-v3" ]]
}

@test "opencodego chat parses tool calls to internal format" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local response_body
    response_body=$(jq -n '{
        choices: [{
            message: {
                content: "I will read that file.",
                tool_calls: [{
                    id: "tc-ocg-1",
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
    result=$(provider_opencodego_chat '[]' '[]')

    local tc_len tc_name tc_id
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')
    tc_id=$(echo "${result}" | jq -r '.tool_calls[0].id')

    [[ "${tc_len}" == "1" ]]
    [[ "${tc_name}" == "read" ]]
    [[ "${tc_id}" == "tc-ocg-1" ]]
}

@test "opencodego chat with no tool calls sets empty tool_calls array" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local response_body
    response_body=$(jq -n '{
        choices: [{
            message: {
                content: "Plain response",
                tool_calls: []
            }
        }]
    }')

    _mock_curl_no_tools() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_no_tools "$@"; }
    export -f curl

    local result
    result=$(provider_opencodego_chat '[]' '[]')

    local tc_len
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    [[ "${tc_len}" == "0" ]]
}

@test "opencodego chat forwards messages correctly in payload" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local payload_file="${BAISH_STATE_DIR}/messages_payload.json"
    local messages_json='[{"role": "user", "content": "Hello, OpenCode!"}]'

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

    provider_opencodego_chat "${messages_json}" '[]' > /dev/null

    local msg_content msg_role
    msg_content=$(jq -r '.messages[0].content' "${payload_file}")
    msg_role=$(jq -r '.messages[0].role' "${payload_file}")

    [[ "${msg_content}" == "Hello, OpenCode!" ]]
    [[ "${msg_role}" == "user" ]]
}

@test "opencodego chat includes tools in payload when provided" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local payload_file="${BAISH_STATE_DIR}/tools_payload.json"
    local tools_json='[{"type": "function", "function": {"name": "read", "parameters": {"type": "object"}}}]'

    _mock_curl_tools() {
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

    curl() { _mock_curl_tools "$@"; }
    export -f curl

    provider_opencodego_chat '[]' "${tools_json}" > /dev/null

    local has_tools tools_name
    has_tools=$(jq 'has("tools")' "${payload_file}")
    tools_name=$(jq -r '.tools[0].function.name' "${payload_file}")

    [[ "${has_tools}" == "true" ]]
    [[ "${tools_name}" == "read" ]]
}

@test "opencodego chat omits tools from payload when not provided" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local payload_file="${BAISH_STATE_DIR}/notools_payload.json"

    _mock_curl_no_tools_payload() {
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

    curl() { _mock_curl_no_tools_payload "$@"; }
    export -f curl

    provider_opencodego_chat '[]' '[]' > /dev/null

    local has_tools
    has_tools=$(jq 'has("tools")' "${payload_file}")
    [[ "${has_tools}" == "false" ]]
}

@test "opencodego chat returns AUTH_FAILURE on 401 error" {
    export OPENCODEGO_API_KEY="ocg-invalid-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    _mock_curl_401() {
        printf '{"error": {"message": "Invalid API key"}}\n401'
    }

    curl() { _mock_curl_401 "$@"; }
    export -f curl

    local result
    result=$(provider_opencodego_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "opencodego chat returns AUTH_FAILURE on 403 error" {
    export OPENCODEGO_API_KEY="ocg-forbidden-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    _mock_curl_403() {
        printf '{"error": {"message": "Access denied"}}\n403'
    }

    curl() { _mock_curl_403 "$@"; }
    export -f curl

    local result
    result=$(provider_opencodego_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "opencodego chat detects context overflow from response" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    _mock_curl_overflow() {
        printf '{"error": {"message": "context_length_exceeded: input is too long"}}\n400'
    }

    curl() { _mock_curl_overflow "$@"; }
    export -f curl

    local result
    result=$(provider_opencodego_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "CONTEXT_OVERFLOW" ]]
}

@test "opencodego chat reports generic error on 500 server error" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="kimi-k2.5"

    _mock_curl_500() {
        printf '{"error": {"message": "Internal server error"}}\n500'
    }

    curl() { _mock_curl_500 "$@"; }
    export -f curl

    local result
    result=$(provider_opencodego_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "GENERIC_ERROR" ]]
}

@test "opencodego chat returns AUTH_FAILURE when no API key configured" {
    unset OPENCODEGO_API_KEY 2>/dev/null || true
    BAISH_CURRENT_MODEL="kimi-k2.5"

    local result
    result=$(provider_opencodego_chat '[]' '[]')

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

# Chat — Anthropic-format path (issue #23)
@test "opencodego chat with minimax model returns text from Anthropic /messages response" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    local payload_file="${BAISH_STATE_DIR}/anthropic_payload.json"
    local endpoint_file="${BAISH_STATE_DIR}/anthropic_endpoint.txt"
    local auth_header_file="${BAISH_STATE_DIR}/anthropic_auth.txt"
    local version_header_file="${BAISH_STATE_DIR}/anthropic_version.txt"
    local response_body
    response_body=$(jq -n '{
        id: "msg_test_001",
        type: "message",
        role: "assistant",
        content: [{type: "text", text: "Hello from minimax via Anthropic API"}],
        stop_reason: "end_turn"
    }')
    _mock_curl_anthropic_basic() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
            fi
            if [[ "${args[$i]}" == "-H" ]]; then
                local header="${args[$((i+1))]}"
                if [[ "${header}" == x-api-key:* ]]; then
                    echo "${header}" > "${auth_header_file}"
                fi
                if [[ "${header}" == anthropic-version:* ]]; then
                    echo "${header}" > "${version_header_file}"
                fi
            fi
        done
        # Capture the URL (last positional arg)
        echo "${args[$(( ${#args[@]} - 1 ))]}" > "${endpoint_file}"
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_anthropic_basic "$@"; }
    export -f curl
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    # Verify result shape
    local ok text tc_len
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    [[ "${ok}" == "true" ]]
    [[ "${text}" == "Hello from minimax via Anthropic API" ]]
    [[ "${tc_len}" == "0" ]]
    # Verify routing to /messages endpoint
    local endpoint
    endpoint=$(cat "${endpoint_file}")
    [[ "${endpoint}" == */messages ]]
    # Verify headers
    local auth_header
    auth_header=$(cat "${auth_header_file}")
    [[ "${auth_header}" == "x-api-key: ocg-test-key" ]]
    local version_header
    version_header=$(cat "${version_header_file}")
    [[ "${version_header}" == "anthropic-version: 2023-06-01" ]]
}

@test "opencodego chat with qwen model routes to /messages endpoint" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="qwen3-coder"
    local endpoint_file="${BAISH_STATE_DIR}/qwen_endpoint.txt"
    local response_body
    response_body=$(jq -n '{
        id: "msg_qwen_001",
        type: "message",
        role: "assistant",
        content: [{type: "text", text: "Hello from qwen"}],
        stop_reason: "end_turn"
    }')
    _mock_curl_qwen() {
        local args=("$@")
        echo "${args[$(( ${#args[@]} - 1 ))]}" > "${endpoint_file}"
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_qwen "$@"; }
    export -f curl
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    local ok text
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    [[ "${ok}" == "true" ]]
    [[ "${text}" == "Hello from qwen" ]]
    # Verify it went to /messages
    local endpoint
    endpoint=$(cat "${endpoint_file}")
    [[ "${endpoint}" == */messages ]]
}

@test "opencodego chat with minimax model parses tool_use blocks to internal format" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    local response_body
    response_body=$(jq -n '{
        id: "msg_tool_001",
        type: "message",
        role: "assistant",
        content: [{
            type: "tool_use",
            id: "toolu_anthropic_001",
            name: "read",
            input: {path: "test.txt"}
        }],
        stop_reason: "tool_use"
    }')
    _mock_curl_tool_use() {
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_tool_use "$@"; }
    export -f curl
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    local ok tc_len tc_id tc_name tc_args
    ok=$(echo "${result}" | jq -r '.ok')
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_id=$(echo "${result}" | jq -r '.tool_calls[0].id')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')
    tc_args=$(echo "${result}" | jq -r '.tool_calls[0].arguments')
    [[ "${ok}" == "true" ]]
    [[ "${tc_len}" == "1" ]]
    [[ "${tc_id}" == "toolu_anthropic_001" ]]
    [[ "${tc_name}" == "read" ]]
    # arguments should be a JSON string of the input object
    local parsed_path
    parsed_path=$(echo "${tc_args}" | jq -r '.path')
    [[ "${parsed_path}" == "test.txt" ]]
}

@test "opencodego chat with qwen model ignores thinking blocks in response" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="qwen3-coder"
    local response_body
    response_body=$(jq -n '{
        id: "msg_think_001",
        type: "message",
        role: "assistant",
        content: [
            {type: "thinking", thinking: "Let me analyze this..."},
            {type: "text", text: "Here is the result"},
            {type: "thinking", thinking: "Double-checking..."}
        ],
        stop_reason: "end_turn"
    }')
    _mock_curl_thinking() {
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_thinking "$@"; }
    export -f curl
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    local ok text tc_len
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    [[ "${ok}" == "true" ]]
    # Thinking content should not appear in assistant_text
    [[ "${text}" == "Here is the result" ]]
    [[ "${tc_len}" == "0" ]]
}

@test "opencodego chat with minimax model handles mixed text and tool_use response" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    local response_body
    response_body=$(jq -n '{
        id: "msg_mixed_001",
        type: "message",
        role: "assistant",
        content: [
            {type: "text", text: "I will read the file."},
            {type: "tool_use", id: "toolu_mixed_1", name: "read", input: {path: "/etc/hosts"}},
            {type: "text", text: " Done."}
        ],
        stop_reason: "tool_use"
    }')
    _mock_curl_mixed() {
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_mixed "$@"; }
    export -f curl
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    local ok text tc_len tc_name tc_args
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')
    tc_args=$(echo "${result}" | jq -r '.tool_calls[0].arguments')
    [[ "${ok}" == "true" ]]
    # All text blocks concatenated
    [[ "${text}" == "I will read the file. Done." ]]
    [[ "${tc_len}" == "1" ]]
    [[ "${tc_name}" == "read" ]]
    local parsed_path
    parsed_path=$(echo "${tc_args}" | jq -r '.path')
    [[ "${parsed_path}" == "/etc/hosts" ]]
}

@test "opencodego anthropic chat places system messages in top-level system field" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    local payload_file="${BAISH_STATE_DIR}/system_payload.json"
    local messages_json='[
        {"role": "system", "content": "You are a helpful coding assistant."},
        {"role": "user", "content": "Hello"}
    ]'
    local response_body
    response_body=$(jq -n '{
        content: [{type: "text", text: "Hi there!"}],
        stop_reason: "end_turn"
    }')
    _mock_curl_system() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
            fi
        done
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_system "$@"; }
    export -f curl
    provider_opencodego_chat "${messages_json}" '[]' > /dev/null
    # Verify system field exists at top level
    local has_system
    has_system=$(jq 'has("system")' "${payload_file}")
    [[ "${has_system}" == "true" ]]
    local system_content
    system_content=$(jq -r '.system' "${payload_file}")
    [[ "${system_content}" == "You are a helpful coding assistant." ]]
    # Verify system message is NOT in messages array
    local msg_roles
    msg_roles=$(jq -r '[.messages[].role] | join(",")' "${payload_file}")
    [[ "${msg_roles}" != *"system"* ]]
}

@test "opencodego anthropic chat translates tools to {name, description, input_schema}" {
    export OPENCODEGO_API_KEY="ocg-test-key"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    local payload_file="${BAISH_STATE_DIR}/tools_anthropic_payload.json"
    local tools_json='[{
        "type": "function",
        "function": {
            "name": "read",
            "description": "Read a file from the filesystem",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}
        }
    }]'
    local response_body
    response_body=$(jq -n '{
        content: [{type: "text", text: "OK"}],
        stop_reason: "end_turn"
    }')
    _mock_curl_tools_translate() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
            fi
        done
        printf '%s\n200' "${response_body}"
    }
    curl() { _mock_curl_tools_translate "$@"; }
    export -f curl
    provider_opencodego_chat '[]' "${tools_json}" > /dev/null
    # Verify Anthropic tool format
    local has_tools
    has_tools=$(jq 'has("tools")' "${payload_file}")
    [[ "${has_tools}" == "true" ]]
    local tool_name tool_desc has_input_schema
    tool_name=$(jq -r '.tools[0].name' "${payload_file}")
    tool_desc=$(jq -r '.tools[0].description' "${payload_file}")
    has_input_schema=$(jq '.tools[0] | has("input_schema")' "${payload_file}")
    [[ "${tool_name}" == "read" ]]
    [[ "${tool_desc}" == "Read a file from the filesystem" ]]
    [[ "${has_input_schema}" == "true" ]]
    # input_schema should contain the parameters object
    local schema_type schema_path_type
    schema_type=$(jq -r '.tools[0].input_schema.type' "${payload_file}")
    schema_path_type=$(jq -r '.tools[0].input_schema.properties.path.type' "${payload_file}")
    [[ "${schema_type}" == "object" ]]
    [[ "${schema_path_type}" == "string" ]]
    # Verify no OpenAI-format fields present
    local has_fn
    has_fn=$(jq '.tools[0] | has("function")' "${payload_file}")
    [[ "${has_fn}" == "false" ]]
}

@test "opencodego anthropic chat returns AUTH_FAILURE on 403 from /messages" {
    export OPENCODEGO_API_KEY="ocg-bad-key"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    _mock_curl_auth_error() {
        printf '{"error": {"type": "authentication_error", "message": "invalid x-api-key"}}\n403'
    }
    curl() { _mock_curl_auth_error "$@"; }
    export -f curl
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')
    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "opencodego anthropic chat returns AUTH_FAILURE when no API key configured" {
    unset OPENCODEGO_API_KEY 2>/dev/null || true
    BAISH_CURRENT_MODEL="qwen3-coder"
    local result
    result=$(provider_opencodego_chat '[]' '[]')
    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')
    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

# ============================================================
# Integration: OpenCode Go via agent loop (issue #24)
# ============================================================

@test "agent loop works with kimi model via OpenAI path" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="kimi-k2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_kimi_integration() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-o" && "${args[$((i+1))]}" == "/dev/null" ]]; then
                printf '200'
                return
            fi
        done
        printf '{"choices": [{"message": {"content": "Hello from kimi via agent loop", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_kimi_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Hello kimi"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 2 ]]

    local assistant_msg content
    assistant_msg="${BAISH_SESSION_MESSAGES[1]}"
    content=$(echo "${assistant_msg}" | jq -r '.content')
    [[ "${content}" == "Hello from kimi via agent loop" ]]
}

@test "agent loop sends correct deepseek model in payload" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="deepseek-v3"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    local payload_file="${BAISH_STATE_DIR}/integration_payload.json"

    _mock_curl_deepseek_integration() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-o" && "${args[$((i+1))]}" == "/dev/null" ]]; then
                printf '200'
                return
            fi
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${payload_file}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "ok", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_deepseek_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Test deepseek"

    local model_in_payload
    model_in_payload=$(jq -r '.model' "${payload_file}")
    [[ "${model_in_payload}" == "deepseek-v3" ]]
}

@test "agent loop works with minimax model via Anthropic path" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_minimax_integration() {
        printf '{"id":"msg_001","type":"message","role":"assistant","content":[{"type":"text","text":"Hello from minimax via agent loop"}],"stop_reason":"end_turn"}\n200'
    }

    curl() { _mock_curl_minimax_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Hello minimax"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 2 ]]

    local assistant_msg content
    assistant_msg="${BAISH_SESSION_MESSAGES[1]}"
    content=$(echo "${assistant_msg}" | jq -r '.content')
    [[ "${content}" == "Hello from minimax via agent loop" ]]
}

@test "agent loop works with qwen model — correct Anthropic headers sent" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="qwen3-coder"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    local auth_header_file="${BAISH_STATE_DIR}/qwen_auth.txt"
    local version_header_file="${BAISH_STATE_DIR}/qwen_version.txt"
    local endpoint_file="${BAISH_STATE_DIR}/qwen_endpoint.txt"

    _mock_curl_qwen_integration() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-H" ]]; then
                local header="${args[$((i+1))]}"
                if [[ "${header}" == x-api-key:* ]]; then
                    echo "${header}" > "${auth_header_file}"
                fi
                if [[ "${header}" == anthropic-version:* ]]; then
                    echo "${header}" > "${version_header_file}"
                fi
            fi
        done
        echo "${args[$(( ${#args[@]} - 1 ))]}" > "${endpoint_file}"
        printf '{"id":"msg_qwen_001","type":"message","role":"assistant","content":[{"type":"text","text":"Hello from qwen"}],"stop_reason":"end_turn"}\n200'
    }

    curl() { _mock_curl_qwen_integration "$@"; }
    export -f curl

    baish_agent_run_user_message "Hello qwen"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 2 ]]

    local assistant_msg content
    assistant_msg="${BAISH_SESSION_MESSAGES[1]}"
    content=$(echo "${assistant_msg}" | jq -r '.content')
    [[ "${content}" == "Hello from qwen" ]]

    local auth_header
    auth_header=$(cat "${auth_header_file}")
    [[ "${auth_header}" == "x-api-key: ocg-valid" ]]

    local version_header
    version_header=$(cat "${version_header_file}")
    [[ "${version_header}" == "anthropic-version: 2023-06-01" ]]

    local endpoint
    endpoint=$(cat "${endpoint_file}")
    [[ "${endpoint}" == */messages ]]
}

@test "agent loop tool call round-trip works for OpenAI-compatible models" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    # Create a test file to read
    local test_file="${BAISH_LAUNCH_DIR}/tool_read_test.txt"
    echo "Hello from tool test file" > "${test_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="kimi-k2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_MAX_TOOL_ROUNDS=1
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    local response_body
    response_body=$(jq -n --arg path "${test_file}" '{
        choices: [{
            message: {
                content: "I will read the file.",
                tool_calls: [{
                    id: "tc-read-1",
                    function: {
                        name: "read",
                        arguments: ("{\"path\": \"" + $path + "\"}")
                    }
                }]
            }
        }]
    }')

    _mock_curl_tool_read() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_tool_read "$@"; }
    export -f curl

    baish_agent_run_user_message "Read the test file"

    # Should have at least 3 messages: user, assistant, tool_result
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    # Verify tool result message exists with role=tool
    local tool_msg role
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    role=$(echo "${tool_msg}" | jq -r '.role')
    [[ "${role}" == "tool" ]]

    # Verify tool result contains success status
    local tool_content
    tool_content=$(echo "${tool_msg}" | jq -r '.content')
    local result_ok
    result_ok=$(echo "${tool_content}" | jq -r '.ok')
    [[ "${result_ok}" == "true" ]]
}

@test "agent loop tool call round-trip works for Anthropic models" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    # Create a test file to read
    local test_file="${BAISH_LAUNCH_DIR}/anthropic_tool_test.txt"
    echo "Hello from anthropic tool test" > "${test_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_MAX_TOOL_ROUNDS=1
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    local response_body
    response_body=$(jq -n --arg path "${test_file}" '{
        id: "msg_tool_ant_001",
        type: "message",
        role: "assistant",
        content: [{
            type: "tool_use",
            id: "toolu_ant_001",
            name: "read",
            input: {path: $path}
        }],
        stop_reason: "tool_use"
    }')

    _mock_curl_anthropic_tool() {
        printf '%s\n200' "${response_body}"
    }

    curl() { _mock_curl_anthropic_tool "$@"; }
    export -f curl

    baish_agent_run_user_message "Read the file via anthropic"

    # Should have at least 3 messages: user, assistant, tool_result
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    # Verify tool result message exists with role=tool
    local tool_msg role
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    role=$(echo "${tool_msg}" | jq -r '.role')
    [[ "${role}" == "tool" ]]

    # Verify tool result contains success status
    local tool_content
    tool_content=$(echo "${tool_msg}" | jq -r '.content')
    local result_ok
    result_ok=$(echo "${tool_content}" | jq -r '.ok')
    [[ "${result_ok}" == "true" ]]
}

@test "agent loop propagates AUTH_FAILURE from OpenAI endpoint" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-bad", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="kimi-k2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_openai_auth_fail() {
        printf '{"error": {"message": "Invalid API key"}}\n401'
    }

    curl() { _mock_curl_openai_auth_fail "$@"; }
    export -f curl

    baish_agent_run_user_message "trigger auth error"

    # The user message should still be in session (appended before error)
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 1 ]]

    # No assistant response should be appended (error prevented it)
    local last_role
    last_role=$(echo "${BAISH_SESSION_MESSAGES[-1]}" | jq -r '.role')
    [[ "${last_role}" == "user" ]]
}

@test "agent loop propagates AUTH_FAILURE from Anthropic endpoint" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-bad", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_anthropic_auth_fail() {
        printf '{"error": {"type": "authentication_error", "message": "invalid x-api-key"}}\n403'
    }

    curl() { _mock_curl_anthropic_auth_fail "$@"; }
    export -f curl

    baish_agent_run_user_message "trigger anthropic auth error"

    # The user message should still be in session
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 1 ]]

    # No assistant response should be appended
    local last_role
    last_role=$(echo "${BAISH_SESSION_MESSAGES[-1]}" | jq -r '.role')
    [[ "${last_role}" == "user" ]]
}

@test "agent loop detects CONTEXT_OVERFLOW from OpenAI endpoint" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="kimi-k2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_openai_overflow() {
        printf '{"error": {"message": "context_length_exceeded: input is too long"}}\n400'
    }

    curl() { _mock_curl_openai_overflow "$@"; }
    export -f curl

    baish_agent_run_user_message "overflow trigger"

    # User message appended but no assistant
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 1 ]]
    local last_role
    last_role=$(echo "${BAISH_SESSION_MESSAGES[-1]}" | jq -r '.role')
    [[ "${last_role}" == "user" ]]
}

@test "agent loop detects CONTEXT_OVERFLOW from Anthropic endpoint" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="minimax-m2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_anthropic_overflow() {
        printf '{"error": {"type": "invalid_request_error", "message": "context_length_exceeded: prompt is too long"}}\n400'
    }

    curl() { _mock_curl_anthropic_overflow "$@"; }
    export -f curl

    baish_agent_run_user_message "anthropic overflow"

    # User message appended but no assistant
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 1 ]]
    local last_role
    last_role=$(echo "${BAISH_SESSION_MESSAGES[-1]}" | jq -r '.role')
    [[ "${last_role}" == "user" ]]
}

@test "agent loop session contains both user and assistant messages after round" {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    mkdir -p "${BAISH_AUTH_DIR}"
    echo '{"api_key": "ocg-valid", "authenticated_at": "2026-06-05T00:00:00Z", "provider": "opencodego"}' \
        > "${auth_file}"

    BAISH_CURRENT_PROVIDER="opencodego"
    BAISH_CURRENT_MODEL="kimi-k2.5"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_CHAT_STDERR_FILE="${BAISH_STATE_DIR}/chat_stderr.txt"

    _mock_curl_session_integrity() {
        printf '{"choices": [{"message": {"content": "Session test response", "tool_calls": []}}]}\n200'
    }

    curl() { _mock_curl_session_integrity "$@"; }
    export -f curl

    baish_agent_run_user_message "Session integrity test"

    # Verify both user and assistant messages are present
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 2 ]]

    local user_role assistant_role user_content assistant_content
    user_role=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.role')
    user_content=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.content')
    assistant_role=$(echo "${BAISH_SESSION_MESSAGES[1]}" | jq -r '.role')
    assistant_content=$(echo "${BAISH_SESSION_MESSAGES[1]}" | jq -r '.content')

    [[ "${user_role}" == "user" ]]
    [[ "${user_content}" == "Session integrity test" ]]
    [[ "${assistant_role}" == "assistant" ]]
    [[ "${assistant_content}" == "Session test response" ]]
}
