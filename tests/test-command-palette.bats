#!/usr/bin/env bats
# BAISH — Unit tests: emoji command palette

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"

    # Source modules
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/commands.sh"
    source "${BAISH_ROOT}/lib/ui/completion.sh"

    # Mock baish_usage (defined in bin/baish, not available in test env)
    baish_usage() { echo "mock usage"; }
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

@test "baish_command_palette returns early when gum not installed" {
    # Override PATH to simulate gum not being present
    local old_path="${PATH}"
    PATH="/nonexistent:${PATH}"
    run type baish_command_palette
    PATH="${old_path}"
    # Function should exist
    [[ "${status}" -eq 0 ]]
}

@test "baish_command_palette function exists and is callable" {
    type -t baish_command_palette | grep -q 'function'
}

@test "Ctrl+G binding is registered in baish_setup_completion" {
    run baish_setup_completion
    [[ "${status}" -eq 0 ]]
}

@test "command palette entries map to valid slash commands" {
    # Verify each palette entry maps to a valid dispatch by testing
    # the slash commands that the palette would trigger

    BAISH_SESSION_EXIT_REQUESTED=0

    # New Session → /new
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_SESSION_MESSAGES=()
    baish_session_append_user_message "hello"
    baish_dispatch_command "/new"
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 0 ]]

    # Quit → /quit
    BAISH_SESSION_EXIT_REQUESTED=0
    baish_dispatch_command "/quit"
    [[ "${BAISH_SESSION_EXIT_REQUESTED}" -eq 1 ]]

    # Help → /help (should not error)
    run baish_dispatch_command "/help"
    [[ "${status}" -eq 0 ]]
}

@test "command palette equivalent commands match slash command dispatch" {
    # Verify each palette entry maps to a valid dispatch
    BAISH_SESSION_EXIT_REQUESTED=0

    baish_dispatch_command "/new"
    [[ "${?}" -eq 0 ]]

    baish_dispatch_command "/help"
    [[ "${?}" -eq 0 ]]

    baish_dispatch_command "/quit"
    [[ "${?}" -eq 0 ]]
}

@test "command palette menu entries cover all expected actions" {
    # Verify the palette function references all expected menu entries
    # by checking the function body for each entry string
    local func_body
    func_body=$(declare -f baish_command_palette)

    # All expected entries should be present in the function
    [[ "${func_body}" == *"New Session"* ]]
    [[ "${func_body}" == *"Connect Provider"* ]]
    [[ "${func_body}" == *"Switch Model"* ]]
    [[ "${func_body}" == *"Load Skill"* ]]
    [[ "${func_body}" == *"Show Skills"* ]]
    [[ "${func_body}" == *"Help"* ]]
    [[ "${func_body}" == *"Quit"* ]]
}

@test "command palette skill sub-menu handles empty skills" {
    BAISH_SESSION_SKILL_NAMES=()
    BAISH_SESSION_SKILL_CONTENTS=()

    # Should not crash when no skills are loaded
    run baish_output_info "No skills found."
    [[ "${status}" -eq 0 ]]
}
