#!/usr/bin/env bats
# BAISH — Tests: State Persistence (lib/state.sh)

setup() {
    # Isolate to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    BAISH_DEBUG=0
    export BAISH_DEBUG

    # Source modules under test
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# --- baish_state_init ---

@test "baish_state_init creates BAISH_STATE_DIR and auth/ subdirectory" {
    # Remove the directory that setup created
    rm -rf "${BAISH_STATE_DIR}"

    [[ ! -d "${BAISH_STATE_DIR}" ]]

    baish_state_init

    [[ -d "${BAISH_STATE_DIR}" ]]
    [[ -d "${BAISH_STATE_DIR}/auth" ]]
}

@test "baish_state_init is idempotent when directories already exist" {
    # Directories already exist from setup
    run baish_state_init

    [[ "${status}" -eq 0 ]]
    [[ -d "${BAISH_STATE_DIR}" ]]
    [[ -d "${BAISH_STATE_DIR}/auth" ]]
}

# --- baish_state_write ---

@test "baish_state_write writes a valid JSON file at BAISH_STATE_DIR/state.json with provider and model fields" {
    baish_state_write "copilot" "gpt-4"

    [[ -f "${BAISH_STATE_DIR}/state.json" ]]

    local provider model
    provider=$(jq -r '.provider' "${BAISH_STATE_DIR}/state.json")
    model=$(jq -r '.model' "${BAISH_STATE_DIR}/state.json")

    [[ "${provider}" == "copilot" ]]
    [[ "${model}" == "gpt-4" ]]
}

@test "baish_state_write returns 1 when called with empty provider" {
    run baish_state_write "" "gpt-4"

    [[ "${status}" -eq 1 ]]
    [[ ! -f "${BAISH_STATE_DIR}/state.json" ]]
}

@test "baish_state_write returns 1 when called with empty model" {
    run baish_state_write "copilot" ""

    [[ "${status}" -eq 1 ]]
    [[ ! -f "${BAISH_STATE_DIR}/state.json" ]]
}

@test "baish_state_write returns 1 when both provider and model are empty" {
    run baish_state_write "" ""

    [[ "${status}" -eq 1 ]]
    [[ ! -f "${BAISH_STATE_DIR}/state.json" ]]
}

@test "baish_state_write overwrites existing state file" {
    baish_state_write "copilot" "gpt-4"
    baish_state_write "kilo" "claude-3"

    local provider model
    provider=$(jq -r '.provider' "${BAISH_STATE_DIR}/state.json")
    model=$(jq -r '.model' "${BAISH_STATE_DIR}/state.json")

    [[ "${provider}" == "kilo" ]]
    [[ "${model}" == "claude-3" ]]
}

@test "baish_state_write returns 0 on success" {
    run baish_state_write "copilot" "gpt-4"

    [[ "${status}" -eq 0 ]]
}

# --- baish_state_read ---

@test "baish_state_read returns 0 and sets BAISH_STATE_PROVIDER and BAISH_STATE_MODEL from a valid file" {
    baish_state_write "copilot" "gpt-4"

    unset BAISH_STATE_PROVIDER BAISH_STATE_MODEL

    baish_state_read

    [[ "${status}" -eq 0 ]]
    [[ "${BAISH_STATE_PROVIDER}" == "copilot" ]]
    [[ "${BAISH_STATE_MODEL}" == "gpt-4" ]]
}

@test "baish_state_read returns 1 when the state file does not exist" {
    [[ ! -f "${BAISH_STATE_DIR}/state.json" ]]

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read returns 1 when the state file is missing provider field" {
    echo '{"model": "gpt-4"}' > "${BAISH_STATE_DIR}/state.json"

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read returns 1 when the state file is missing model field" {
    echo '{"provider": "copilot"}' > "${BAISH_STATE_DIR}/state.json"

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read returns 1 when the state file has empty provider" {
    echo '{"provider": "", "model": "gpt-4"}' > "${BAISH_STATE_DIR}/state.json"

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read returns 1 when the state file has empty model" {
    echo '{"provider": "copilot", "model": ""}' > "${BAISH_STATE_DIR}/state.json"

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read returns 1 when the state file contains invalid JSON" {
    echo "not valid json" > "${BAISH_STATE_DIR}/state.json"

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read returns 1 when the state file has extra fields but missing provider" {
    echo '{"model": "gpt-4", "extra": "value"}' > "${BAISH_STATE_DIR}/state.json"

    run baish_state_read

    [[ "${status}" -eq 1 ]]
}

@test "baish_state_read does not set variables when returning 1" {
    echo '{}' > "${BAISH_STATE_DIR}/state.json"

    BAISH_STATE_PROVIDER="old"
    BAISH_STATE_MODEL="old"
    run baish_state_read

    [[ "${status}" -eq 1 ]]
    [[ "${BAISH_STATE_PROVIDER}" == "old" ]]
    [[ "${BAISH_STATE_MODEL}" == "old" ]]
}

# --- Round-trip test ---

@test "round-trip: write then read returns the same values" {
    baish_state_write "kilo" "claude-3-opus"

    unset BAISH_STATE_PROVIDER BAISH_STATE_MODEL

    baish_state_read

    [[ "${BAISH_STATE_PROVIDER}" == "kilo" ]]
    [[ "${BAISH_STATE_MODEL}" == "claude-3-opus" ]]
}

@test "round-trip: write with different values then read" {
    baish_state_write "opencodego" "gpt-4o"

    unset BAISH_STATE_PROVIDER BAISH_STATE_MODEL

    baish_state_read

    [[ "${BAISH_STATE_PROVIDER}" == "opencodego" ]]
    [[ "${BAISH_STATE_MODEL}" == "gpt-4o" ]]
}
