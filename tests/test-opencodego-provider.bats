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
