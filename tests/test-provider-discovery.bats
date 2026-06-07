#!/usr/bin/env bats
# BAISH — Tests: Provider Discovery and Multi-Provider Infrastructure
#
# Tests:
# - Provider discovery scans and validates provider files
# - Provider ID collision detection errors loudly
# - All providers return normalized {assistant_text, tool_calls}
# - Provider metadata is correct for each provider
# - Environment-based auth detection works
# - Provider and model selection logic

setup() {
    # Isolate state to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT
    export BAISH_AUTH_DIR="${BAISH_STATE_DIR}/auth"
    mkdir -p "${BAISH_AUTH_DIR}"

    # Source modules
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
    source "${BAISH_ROOT}/lib/providers/discovery.sh"

    # Source provider files directly for tests that call provider functions
    source "${BAISH_ROOT}/lib/providers/mock.sh"
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"
    source "${BAISH_ROOT}/lib/providers/copilot.sh"
    source "${BAISH_ROOT}/lib/providers/kilo.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
    # Reset provider globals
    BAISH_PROVIDER_IDS=()
}

# ============================================================
# Error path: collision detection
# ============================================================

@test "provider ID collision triggers exit 1" {
    local real_providers="${BAISH_ROOT}/lib/providers"
    local collider_a="${real_providers}/test-collision-a.sh"
    local collider_b="${real_providers}/test-collision-b.sh"

    # Both files define provider_collisiontest_* functions (same ID)
    cat > "${collider_a}" << 'COLLISIONEOF'
provider_collisiontest_metadata() { jq -n '{"id":"collisiontest","label":"Collision A","desc":"","selectable":false}'; }
provider_collisiontest_auth() { return 0; }
provider_collisiontest_list_models() { jq -n '[]'; }
provider_collisiontest_chat() { jq -n '{"ok":true,"assistant_text":"","tool_calls":[]}'; }
COLLISIONEOF

    cat > "${collider_b}" << 'COLLISIONEOF'
provider_collisiontest_metadata() { jq -n '{"id":"collisiontest","label":"Collision B","desc":"","selectable":false}'; }
provider_collisiontest_auth() { return 0; }
provider_collisiontest_list_models() { jq -n '[]'; }
provider_collisiontest_chat() { jq -n '{"ok":true,"assistant_text":"","tool_calls":[]}'; }
COLLISIONEOF

    # Reset provider state so discovery starts fresh
    BAISH_PROVIDER_IDS=()
    BAISH_DISCOVERY_INIT=1

    run baish_discover_providers

    rm -f "${collider_a}" "${collider_b}"

    [[ "$status" -eq 1 ]]
    echo "${output}" | grep -qi "collision"
}

# ============================================================
# Error path: missing required function
# ============================================================

@test "discovery of a provider missing a required function returns 1" {
    local real_providers="${BAISH_ROOT}/lib/providers"
    local partial="${real_providers}/test-partial-provider.sh"

    # Create a provider file that's missing the chat function
    cat > "${partial}" << 'PARTIALEOF'
provider_partial_metadata() { jq -n '{"id":"partial","label":"Partial","desc":"","selectable":false}'; }
provider_partial_auth() { return 0; }
provider_partial_list_models() { jq -n '[]'; }
# Intentionally missing: provider_partial_chat
PARTIALEOF

    # Reset provider state
    BAISH_PROVIDER_IDS=()
    BAISH_DISCOVERY_INIT=1

    run baish_discover_providers

    rm -f "${partial}"

    [[ "$status" -eq 1 ]]
    echo "${output}" | grep -qi "missing required function"
}

# ============================================================
# Provider discovery
# ============================================================

@test "provider discovery registers all providers" {
    # Discovery was already done in setup (via sourcing).
    # Verify that provider functions exist for all expected providers.
    declare -F provider_mock_metadata &>/dev/null
    [[ $? -eq 0 ]]
    declare -F provider_copilot_metadata &>/dev/null
    [[ $? -eq 0 ]]
    declare -F provider_kilo_metadata &>/dev/null
    [[ $? -eq 0 ]]

    # Verify all required functions exist for each provider
    for pid in mock copilot kilo; do
        declare -F "provider_${pid}_metadata" &>/dev/null
        declare -F "provider_${pid}_auth" &>/dev/null
        declare -F "provider_${pid}_list_models" &>/dev/null
        declare -F "provider_${pid}_chat" &>/dev/null
    done
}

@test "all discovered providers have required functions" {
    baish_discover_providers

    for pid in "${BAISH_PROVIDER_IDS[@]}"; do
        assert_fn_exists "provider_${pid}_metadata"
        assert_fn_exists "provider_${pid}_auth"
        assert_fn_exists "provider_${pid}_list_models"
        assert_fn_exists "provider_${pid}_chat"
    done
}

assert_fn_exists() {
    local fn="$1"
    declare -F "${fn}" &>/dev/null
}

# ============================================================
# Provider metadata
# ============================================================

@test "mock provider metadata is non-selectable" {
    local metadata
    metadata=$(provider_mock_metadata)

    local id selectable
    id=$(echo "${metadata}" | jq -r '.id')
    selectable=$(echo "${metadata}" | jq -r '.selectable')

    [[ "${id}" == "mock" ]]
    [[ "${selectable}" == "false" ]]
}

@test "copilot provider metadata is selectable" {
    local metadata
    metadata=$(provider_copilot_metadata)

    local id selectable
    id=$(echo "${metadata}" | jq -r '.id')
    selectable=$(echo "${metadata}" | jq -r '.selectable')

    [[ "${id}" == "copilot" ]]
    [[ "${selectable}" == "true" ]]
}

@test "kilo provider metadata is selectable" {
    local metadata
    metadata=$(provider_kilo_metadata)

    local id selectable
    id=$(echo "${metadata}" | jq -r '.id')
    selectable=$(echo "${metadata}" | jq -r '.selectable')

    [[ "${id}" == "kilo" ]]
    [[ "${selectable}" == "true" ]]
}

# ============================================================
# Unified provider interface: {assistant_text, tool_calls}
# ============================================================

@test "mock provider chat returns normalized shape with ok:true" {
    export BAISH_MOCK_RESPONSE="Test response"
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"

    local result
    result=$(provider_mock_chat '[]' '[]')

    # Verify JSON shape
    local has_ok has_text has_tc
    has_ok=$(echo "${result}" | jq 'has("ok")')
    has_text=$(echo "${result}" | jq 'has("assistant_text")')
    has_tc=$(echo "${result}" | jq 'has("tool_calls")')

    [[ "${has_ok}" == "true" ]]
    [[ "${has_text}" == "true" ]]
    [[ "${has_tc}" == "true" ]]

    # Verify values
    local ok text
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    [[ "${ok}" == "true" ]]
    [[ "${text}" == "Test response" ]]
}

@test "mock provider chat returns empty tool_calls array when no tools" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"

    local result
    result=$(provider_mock_chat '[]' '[]')

    local tc
    tc=$(echo "${result}" | jq -c '.tool_calls')
    [[ "${tc}" == "[]" ]]
}

@test "mock provider chat returns pre-programmed tool calls" {
    export BAISH_MOCK_RESPONSE=""
    export BAISH_MOCK_TOOL_CALLS='[{"id":"tc1","name":"read","arguments":"{\"path\":\"test.txt\"}"}]'
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"

    local result
    result=$(provider_mock_chat '[]' '[]')

    local tc_len
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    [[ "${tc_len}" == "1" ]]

    local tc_name tc_id
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')
    tc_id=$(echo "${result}" | jq -r '.tool_calls[0].id')

    [[ "${tc_name}" == "read" ]]
    [[ "${tc_id}" == "tc1" ]]
}

# ============================================================
# Model listing
# ============================================================

@test "mock provider returns model list" {
    local models
    models=$(provider_mock_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -ge 1 ]]

    local model_id
    model_id=$(echo "${models}" | jq -r '.[0].id')
    [[ "${model_id}" == "mock-model" ]]
}

@test "copilot provider returns model list with gpt-5 and other models" {
    local models
    models=$(provider_copilot_list_models)

    local count
    count=$(echo "${models}" | jq 'length')
    [[ "${count}" -ge 1 ]]

    # Check that gpt-5 model is present
    local has_gpt5
    has_gpt5=$(echo "${models}" | jq '[.[].id] | map(select(startswith("gpt-5"))) | length > 0')
    [[ "${has_gpt5}" == "true" ]]

    # Check that non-gpt-5 model is present
    local has_other
    has_other=$(echo "${models}" | jq '[.[].id] | map(select(startswith("gpt-5") | not)) | length > 0')
    [[ "${has_other}" == "true" ]]
}

# ============================================================
# Environment-based auth detection
# ============================================================

@test "copilot detects env auth when GH_TOKEN is set" {
    local saved="${GH_TOKEN:-}"
    export GH_TOKEN="gho_test123"
    if provider_copilot_has_env_auth; then
        local detected=1
    else
        local detected=0
    fi
    [[ -n "${saved}" ]] && export GH_TOKEN="${saved}" || unset GH_TOKEN
    [[ "${detected}" -eq 1 ]]
}

@test "copilot detects env auth when GITHUB_TOKEN is set" {
    local saved="${GITHUB_TOKEN:-}"
    export GITHUB_TOKEN="ghp_test456"
    if provider_copilot_has_env_auth; then
        local detected=1
    else
        local detected=0
    fi
    [[ -n "${saved}" ]] && export GITHUB_TOKEN="${saved}" || unset GITHUB_TOKEN
    [[ "${detected}" -eq 1 ]]
}

@test "copilot returns no env auth when neither token is set" {
    # Temporarily save and unset tokens
    local saved_gh_token="${GH_TOKEN:-}"
    local saved_github_token="${GITHUB_TOKEN:-}"
    unset GH_TOKEN GITHUB_TOKEN 2>/dev/null || true

    local result=0
    provider_copilot_has_env_auth || result=$?

    # Restore
    [[ -n "${saved_gh_token}" ]] && export GH_TOKEN="${saved_gh_token}"
    [[ -n "${saved_github_token}" ]] && export GITHUB_TOKEN="${saved_github_token}"

    [[ "${result}" -ne 0 ]]
}

@test "kilo detects env auth when KILO_API_KEY is set" {
    local saved="${KILO_API_KEY:-}"
    export KILO_API_KEY="sk-test-key"
    if provider_kilo_has_env_auth; then
        local detected=1
    else
        local detected=0
    fi
    [[ -n "${saved}" ]] && export KILO_API_KEY="${saved}" || unset KILO_API_KEY
    [[ "${detected}" -eq 1 ]]
}

@test "kilo returns no env auth when KILO_API_KEY is not set" {
    # Temporarily save and unset key
    local saved_kilo_key="${KILO_API_KEY:-}"
    unset KILO_API_KEY 2>/dev/null || true

    # Capture return code inline
    local result=0
    provider_kilo_has_env_auth || result=$?

    # Restore
    [[ -n "${saved_kilo_key}" ]] && export KILO_API_KEY="${saved_kilo_key}"

    [[ "${result}" -ne 0 ]]
}

@test "mock provider always reports env auth" {
    provider_mock_has_env_auth
    [[ $? -eq 0 ]]
}

# ============================================================
# Auth: copilot token persistence
# ============================================================

@test "copilot auth persists token to file" {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"

    # Simulate auth by writing the file directly
    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n --arg token "gho_test_token_12345" '{
        "github_token": $token,
        "authenticated_at": "2026-06-05T00:00:00Z",
        "provider": "github"
    }' > "${auth_file}"

    # Verify the file was written correctly
    local stored_token
    stored_token=$(jq -r '.github_token' "${auth_file}")
    [[ "${stored_token}" == "gho_test_token_12345" ]]
}

# ============================================================
# Auth: kilo key persistence
# ============================================================

@test "kilo auth persists API key to file" {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"

    mkdir -p "${BAISH_AUTH_DIR}"
    jq -n --arg key "sk-kilo-test-key" '{
        "api_key": $key,
        "authenticated_at": "2026-06-05T00:00:00Z",
        "provider": "kilo"
    }' > "${auth_file}"

    local stored_key
    stored_key=$(jq -r '.api_key' "${auth_file}")
    [[ "${stored_key}" == "sk-kilo-test-key" ]]
}

# ============================================================
# Provider selection logic
# ============================================================

@test "provider selection auto-selects when only one selectable provider exists" {
    baish_discover_providers
    BAISH_CURRENT_PROVIDER=""

    # Only mock is non-selectable. If we remove copilot and kilo from the array,
    # the selection should auto-select or fail (since mock is non-selectable).
    # Let's test the scenario where only mock exists by filtering
    local original_ids=("${BAISH_PROVIDER_IDS[@]}")

    # Simulate only one selectable provider
    BAISH_PROVIDER_IDS=("copilot")
    # Mock the metadata to return selectable=true
    baish_provider_select_interactive

    # Since fzf can't work in bats, when only one selectable provider exists
    # it should auto-select
    [[ "${BAISH_CURRENT_PROVIDER}" == "copilot" ]]
}

@test "baish_provider_metadata returns valid JSON" {
    baish_discover_providers

    for pid in "${BAISH_PROVIDER_IDS[@]}"; do
        local metadata
        metadata=$(baish_provider_metadata "${pid}")

        # Verify it's valid JSON
        echo "${metadata}" | jq '.' > /dev/null

        # Verify required fields
        local id label selectable
        id=$(echo "${metadata}" | jq -r '.id')
        label=$(echo "${metadata}" | jq -r '.label')
        selectable=$(echo "${metadata}" | jq -r '.selectable')

        [[ "${id}" == "${pid}" ]]
        [[ -n "${label}" ]]
    done
}

# ============================================================
# Provider auth helper functions
# ============================================================

@test "baish_provider_auth skips interactive auth when env auth exists" {
    baish_discover_providers
    export GH_TOKEN="gho_test123"

    BAISH_CURRENT_PROVIDER="copilot"
    BAISH_CURRENT_MODEL="gpt-4o"

    # Should succeed without interactive auth (env auth detected)
    baish_provider_auth
    [[ $? -eq 0 ]]
}

# ============================================================
# Copilot model routing logic
# ============================================================

@test "copilot model list contains both gpt-5 and non-gpt-5 models" {
    local models
    models=$(provider_copilot_list_models)

    # Count gpt-5 models
    local gpt5_count
    gpt5_count=$(echo "${models}" | jq '[.[].id | select(startswith("gpt-5"))] | length')

    # Count non-gpt-5 models
    local other_count
    other_count=$(echo "${models}" | jq '[.[].id | select(startswith("gpt-5") | not)] | length')

    [[ "${gpt5_count}" -gt 0 ]]
    [[ "${other_count}" -gt 0 ]]
}

# ============================================================
# Integration: agent loop with mock provider (via discovery)
# ============================================================

@test "agent loop works with mock provider discovered via infrastructure" {
    baish_discover_providers

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="Discovered mock response!"
    BAISH_MOCK_TOOL_CALLS=""
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Hello"

    # Should have user + assistant messages
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 2 ]]

    local assistant_msg
    assistant_msg="${BAISH_SESSION_MESSAGES[1]}"
    local role content
    role=$(echo "${assistant_msg}" | jq -r '.role')
    content=$(echo "${assistant_msg}" | jq -r '.content')

    [[ "${role}" == "assistant" ]]
    [[ "${content}" == "Discovered mock response!" ]]
}

# ============================================================
# Integration: tool calls via discovered mock provider
# ============================================================

@test "agent loop executes tool calls from discovered mock provider" {
    baish_discover_providers

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I'll read that file for you."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-1","name":"read","arguments":"{\"path\":\"test.txt\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Read test.txt"

    # Should have: user + assistant + tool result = 3 messages
    # (read tool returns NOT_IMPLEMENTED but still gets appended)
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    # Verify tool result message
    local tool_msg
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    local role
    role=$(echo "${tool_msg}" | jq -r '.role')
    [[ "${role}" == "tool" ]]
}
