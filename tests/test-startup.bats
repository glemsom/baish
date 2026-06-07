#!/usr/bin/env bats
# BAISH — Tests: Agent startup module (lib/agent/startup.sh)

setup() {
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"
    export BAISH_AUTH_DIR="${BAISH_STATE_DIR}/auth"
    mkdir -p "${BAISH_AUTH_DIR}"

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Source core modules startup.sh depends on
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
    source "${BAISH_ROOT}/lib/providers/mock.sh"
    source "${BAISH_ROOT}/lib/providers/discovery.sh"

    # Source the module under test
    source "${BAISH_ROOT}/lib/agent/startup.sh"

    # Reset provider globals
    BAISH_PROVIDER_IDS=()
    BAISH_CURRENT_PROVIDER=""
    BAISH_CURRENT_MODEL=""

    baish_state_init
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
    BAISH_PROVIDER_IDS=()
}

# Helper: define a selectable stub provider for tests that need one.
# mock.sh has selectable:false, so we need a separate stub to reach the
# injected picker path in baish_startup.
_define_stub_provider() {
    provider_stub_metadata() {
        jq -n '{"id": "stub", "label": "Stub", "desc": "", "selectable": true}'
    }
    provider_stub_auth() { return 0; }
    provider_stub_list_models() { jq -n '[{"id": "stub-model", "name": "Stub Model"}]'; }
    provider_stub_chat() { jq -n '{"ok":true,"assistant_text":"","tool_calls":[]}'; }
}

# ── baish_startup: injectable pickers ──────────────────────────────────

@test "baish_startup uses injected provider and model pickers" {
    _define_stub_provider
    BAISH_PROVIDER_IDS=("stub")

    # Inject non-interactive pickers
    mock_picker() {
        BAISH_CURRENT_PROVIDER="stub"
        return 0
    }
    mock_model_picker() {
        BAISH_CURRENT_MODEL="stub-model"
        return 0
    }
    BAISH_STARTUP_PROVIDER_PICKER=mock_picker
    BAISH_STARTUP_MODEL_PICKER=mock_model_picker

    # No state file — should fall through to injected pickers
    baish_startup

    [[ "${BAISH_CURRENT_PROVIDER}" == "stub" ]]
    [[ "${BAISH_CURRENT_MODEL}" == "stub-model" ]]
}

@test "baish_startup returns error when injected picker fails" {
    _define_stub_provider
    BAISH_PROVIDER_IDS=("stub")

    mock_picker() {
        # Simulate user cancelling selection
        return 1
    }
    BAISH_STARTUP_PROVIDER_PICKER=mock_picker

    run baish_startup

    [[ "${status}" -ne 0 ]]
    # Error message should mention provider selection
    [[ "${output}" == *"No provider selected"* ]]
}

@test "baish_startup returns error when injected model picker fails" {
    _define_stub_provider
    BAISH_PROVIDER_IDS=("stub")

    mock_picker() {
        BAISH_CURRENT_PROVIDER="stub"
        return 0
    }
    mock_model_picker() {
        return 1
    }
    BAISH_STARTUP_PROVIDER_PICKER=mock_picker
    BAISH_STARTUP_MODEL_PICKER=mock_model_picker

    run baish_startup

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"No model selected"* ]]
}

# ── baish_startup: state restoration ───────────────────────────────────

@test "baish_startup restores from state when provider exists and has env auth" {
    BAISH_PROVIDER_IDS=("mock")

    # Write state with mock provider
    baish_state_write "mock" "mock-model"

    baish_startup

    [[ "${BAISH_CURRENT_PROVIDER}" == "mock" ]]
    [[ "${BAISH_CURRENT_MODEL}" == "mock-model" ]]
}

@test "baish_startup falls back to pickers when state provider is gone" {
    # State references a provider not in BAISH_PROVIDER_IDS
    baish_state_write "copilot" "gpt-5"

    _define_stub_provider
    BAISH_PROVIDER_IDS=("stub")

    mock_picker() {
        BAISH_CURRENT_PROVIDER="stub"
        return 0
    }
    mock_model_picker() {
        BAISH_CURRENT_MODEL="stub-model"
        return 0
    }
    BAISH_STARTUP_PROVIDER_PICKER=mock_picker
    BAISH_STARTUP_MODEL_PICKER=mock_model_picker

    baish_startup

    [[ "${BAISH_CURRENT_PROVIDER}" == "stub" ]]
    [[ "${BAISH_CURRENT_MODEL}" == "stub-model" ]]
}

@test "baish_startup defaults to mock when no selectable providers exist" {
    # mock is the only provider and it's non-selectable → fallback path
    BAISH_PROVIDER_IDS=("mock")

    baish_startup

    [[ "${BAISH_CURRENT_PROVIDER}" == "mock" ]]
    [[ -n "${BAISH_CURRENT_MODEL}" ]]
}

# ── baish_startup: error paths ─────────────────────────────────────────

@test "baish_startup returns error when no providers at all" {
    BAISH_PROVIDER_IDS=()

    run baish_startup

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"No providers available"* ]]
}

@test "baish_startup returns error when only non-mock non-selectable providers" {
    # A provider that isn't selectable and isn't called "mock"
    provider_ghost_metadata() {
        jq -n '{"id": "ghost", "label": "Ghost", "desc": "", "selectable": false}'
    }
    BAISH_PROVIDER_IDS=("ghost")

    run baish_startup

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"No providers available"* ]]
}
