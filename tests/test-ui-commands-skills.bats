#!/usr/bin/env bats
# BAISH — Tests: Terminal UI, Slash Commands, and Skills System
#
# Tests:
# - Slash command dispatch: /quit, /exit, /new, /connect, /provider, /model, /skill:<name>
# - TAB completion for file paths (starting with @)
# - TAB completion for slash commands (starting with /)
# - Skills system: load, project-local override, persistence across /new
# - System prompt ordering: base → skill messages → conversation history

setup() {
    # Isolate state to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Source all modules
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/skills.sh"
    source "${BAISH_ROOT}/lib/agent/agents-md.sh"
    source "${BAISH_ROOT}/lib/agent/commands.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
    source "${BAISH_ROOT}/lib/providers/discovery.sh"
    source "${BAISH_ROOT}/lib/providers/mock.sh"
    source "${BAISH_ROOT}/lib/ui/completion.sh"

    # Mock baish_usage (defined in bin/baish, not available in test env)
    baish_usage() { echo "mock usage"; }
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# ============================================================
# Slash command dispatch
# ============================================================

@test "/quit sets exit requested flag" {
    BAISH_SESSION_EXIT_REQUESTED=0

    baish_dispatch_command "/quit"

    [[ "${BAISH_SESSION_EXIT_REQUESTED}" -eq 1 ]]
}

@test "/exit sets exit requested flag" {
    BAISH_SESSION_EXIT_REQUESTED=0

    baish_dispatch_command "/exit"

    [[ "${BAISH_SESSION_EXIT_REQUESTED}" -eq 1 ]]
}

@test "/new clears messages but preserves provider and model" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_SESSION_MESSAGES=()

    baish_session_append_user_message "hello"
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 1 ]]

    baish_dispatch_command "/new"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 0 ]]
    [[ "${BAISH_CURRENT_PROVIDER}" == "mock" ]]
    [[ "${BAISH_CURRENT_MODEL}" == "mock-model" ]]
}

@test "/new preserves loaded skills" {
    BAISH_SESSION_SKILL_NAMES=("tdd" "testing")
    BAISH_SESSION_SKILL_CONTENTS=("tdd skill content" "testing skill content")

    baish_dispatch_command "/new"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 2 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "tdd" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[1]}" == "testing skill content" ]]
}

@test "unknown slash command returns error" {
    local result
    result=$(baish_dispatch_command "/unknown" 2>&1) || true

    [[ "${result}" == *"Unknown command"* ]]
}

# ============================================================
# /connect, /provider, /model dispatch — guard paths
# ============================================================

@test "/connect prints error when no provider set" {
    BAISH_CURRENT_PROVIDER=""

    run baish_dispatch_command "/connect"

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"Authentication failed"* ]]
}

@test "/provider prints error when no selectable providers available" {
    # mock provider is non-selectable, so with only mock registered
    # baish_provider_select_interactive will find 0 selectable providers.
    BAISH_PROVIDER_IDS=("mock")
    BAISH_CURRENT_PROVIDER=""

    run baish_dispatch_command "/provider"

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"No selectable providers available"* ]]
}

@test "/model prints error when provider has no models" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_PROVIDER_IDS=("mock")

    # Override mock list_models to return empty array
    provider_mock_list_models() {
        echo '[]'
    }

    run baish_dispatch_command "/model"

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"No models available"* ]]
}

@test "/connect, /provider, /model appear in command listing" {
    local completions
    completions=$(baish_complete_commands_stdout "/")

    [[ "${completions}" == *"/connect"* ]]
    [[ "${completions}" == *"/provider"* ]]
    [[ "${completions}" == *"/model"* ]]
}

# ============================================================
# TAB completion — path completion (@)
# ============================================================

@test "path completion finds files starting with @" {
    # Create test files
    local test_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${test_dir}/src"
    touch "${test_dir}/src/main.sh"
    touch "${test_dir}/src/utils.sh"
    touch "${test_dir}/README.md"

    local completions
    completions=$(baish_complete_paths "src/" "${test_dir}")

    [[ "${completions}" == *"src/main.sh"* ]]
    [[ "${completions}" == *"src/utils.sh"* ]]
}

@test "path completion returns directories with trailing slash" {
    local test_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${test_dir}/src"
    mkdir -p "${test_dir}/lib"
    touch "${test_dir}/README.md"

    local completions
    completions=$(baish_complete_input "@" "${test_dir}")

    [[ "${completions}" == *"src/"* ]]
    [[ "${completions}" == *"lib/"* ]]
}

@test "path completion for @ returns no results for non-matching prefix" {
    local test_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${test_dir}"
    touch "${test_dir}/README.md"

    local completions
    completions=$(baish_complete_input "@xyz" "${test_dir}")

    [[ -z "${completions}" ]]
}

# ============================================================
# TAB completion — baish_tab_complete (bind -x handler)
# ============================================================

@test "baish_tab_complete replaces word with single @ path match" {
    local test_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${test_dir}/src"
    touch "${test_dir}/src/main.sh"

    READLINE_LINE="@src/main"
    READLINE_POINT=9
    BAISH_LAUNCH_DIR="${test_dir}"

    baish_tab_complete

    [[ "${READLINE_LINE}" == "@src/main.sh" ]]
    [[ "${READLINE_POINT}" -eq 12 ]]
}

@test "baish_tab_complete replaces word with single / cmd match" {
    READLINE_LINE="/q"
    READLINE_POINT=2

    baish_tab_complete

    [[ "${READLINE_LINE}" == "/quit" ]]
    [[ "${READLINE_POINT}" -eq 5 ]]
}

@test "baish_tab_complete does nothing for non-@ non-/ words" {
    READLINE_LINE="hello"
    READLINE_POINT=5

    baish_tab_complete

    # Should be unchanged
    [[ "${READLINE_LINE}" == "hello" ]]
    [[ "${READLINE_POINT}" -eq 5 ]]
}

@test "baish_tab_complete extends to common prefix for multiple @ matches" {
    local test_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${test_dir}/lib"
    touch "${test_dir}/lib/file_a.sh"
    touch "${test_dir}/lib/file_b.sh"

    READLINE_LINE="@lib/file_"
    READLINE_POINT=10
    BAISH_LAUNCH_DIR="${test_dir}"

    baish_tab_complete

    # Common prefix of file_a.sh and file_b.sh is "file_" — no extension
    [[ "${READLINE_LINE}" == "@lib/file_" ]]
    [[ "${READLINE_POINT}" -eq 10 ]]
}

@test "baish_tab_complete extends common prefix for / cmds" {
    READLINE_LINE="/"
    READLINE_POINT=1

    baish_tab_complete

    # All commands share "/" — no extension, stays at "/"
    # But we verify it doesn't crash
    [[ "${READLINE_LINE}" == "/" ]]
    [[ "${READLINE_POINT}" -eq 1 ]]
}

@test "baish_tab_complete does nothing for empty word (cursor at space)" {
    READLINE_LINE="hello "
    READLINE_POINT=6

    baish_tab_complete

    [[ "${READLINE_LINE}" == "hello " ]]
    [[ "${READLINE_POINT}" -eq 6 ]]
}

@test "baish_setup_completion runs without error" {
    run baish_setup_completion
    [[ "${status}" -eq 0 ]]
}

@test "baish_setup_completion installs readline bindings for @-path and /-command completion" {
    # Bug regression test: bind -x silently fails with "line editing not enabled"
    # in non-interactive shells if set -o emacs is not called first. Without this,
    # baish_tab_complete and baish_command_palette are never bound to \C-i / \C-g.
    # Call setup directly (not via run) so the set -o emacs inside persists.
    baish_setup_completion

    # After setup, bind -X should show both custom keybindings.
    # Avoid `run` because it forks a subshell where readline is not enabled.
    local bind_output
    bind_output=$(bind -X 2>/dev/null)
    [[ -n "${bind_output}" ]]
    [[ "${bind_output}" == *'"\C-i": "baish_tab_complete"'* ]]
    [[ "${bind_output}" == *'"\C-g": "baish_command_palette"'* ]]
}

# ============================================================
# TAB completion — slash command completion (/)
# ============================================================

@test "slash command completion lists available commands" {
    local completions
    completions=$(baish_complete_commands_stdout "/")

    [[ "${completions}" == *"/quit"* ]]
    [[ "${completions}" == *"/exit"* ]]
    [[ "${completions}" == *"/new"* ]]
    [[ "${completions}" == *"/help"* ]]
    [[ "${completions}" == *"/connect"* ]]
    [[ "${completions}" == *"/provider"* ]]
    [[ "${completions}" == *"/model"* ]]
}

@test "slash command completion filters by prefix" {
    local completions
    completions=$(baish_complete_commands_stdout "/q")

    [[ "${completions}" == *"/quit"* ]]
    [[ "${completions}" != *"/new"* ]]
}

@test "slash command completion includes loaded skill commands" {
    BAISH_SESSION_SKILL_NAMES=()
    BAISH_SESSION_SKILL_CONTENTS=()

    # Load a skill into user-global location
    local skill_dir="${BAISH_STATE_DIR}/home/.baish/skills/test-skill"
    mkdir -p "${skill_dir}"
    echo "Test skill content" > "${skill_dir}/SKILL.md"

    baish_skill_load "test-skill"

    local completions
    completions=$(baish_complete_commands_stdout "/skill:")

    [[ "${completions}" == *"/skill:test-skill"* ]]
}

# ============================================================
# Skills system — loading
# ============================================================

@test "skill loads from user-global location" {
    local global_dir="${BAISH_STATE_DIR}/home/.baish/skills/tdd"
    mkdir -p "${global_dir}"
    echo "# TDD Skill" > "${global_dir}/SKILL.md"
    echo "Follow test-driven development" >> "${global_dir}/SKILL.md"

    baish_skill_load "tdd"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "tdd" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == *"# TDD Skill"* ]]
}

@test "skill loads from project-local location" {
    local project_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${project_dir}/.baish/skills/tdd"
    echo "# Project TDD" > "${project_dir}/.baish/skills/tdd/SKILL.md"

    local orig_pwd="${PWD}"
    cd "${project_dir}"

    baish_skill_load "tdd"

    cd "${orig_pwd}"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == *"# Project TDD"* ]]
}

@test "project-local skill overrides user-global skill" {
    # Set up user-global skill
    local global_dir="${BAISH_STATE_DIR}/home/.baish/skills/tdd"
    mkdir -p "${global_dir}"
    echo "# Global TDD" > "${global_dir}/SKILL.md"

    # Set up project-local skill
    local project_dir="${BAISH_STATE_DIR}/project"
    mkdir -p "${project_dir}/.baish/skills/tdd"
    echo "# Local TDD" > "${project_dir}/.baish/skills/tdd/SKILL.md"

    local orig_pwd="${PWD}"
    cd "${project_dir}"

    baish_skill_load "tdd"

    cd "${orig_pwd}"

    # Should load project-local, not global
    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == *"# Local TDD"* ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" != *"# Global TDD"* ]]
}

@test "skill loading is idempotent (skip if already loaded)" {
    local global_dir="${BAISH_STATE_DIR}/home/.baish/skills/tdd"
    mkdir -p "${global_dir}"
    echo "# TDD" > "${global_dir}/SKILL.md"

    baish_skill_load "tdd"
    baish_skill_load "tdd"
    baish_skill_load "tdd"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
}

@test "loading non-existent skill returns error" {
    local result
    result=$(baish_skill_load "nonexistent" 2>&1) || true

    [[ "${result}" == *"not found"* || "${result}" == *"Skill"* ]]
}

# ============================================================
# Skills — system prompt ordering
# ============================================================

@test "system prompt includes skill messages in correct order" {
    BAISH_SYSTEM_PROMPT="You are BAISH."

    # Add two skills
    BAISH_SESSION_SKILL_NAMES=("tdd" "testing")
    BAISH_SESSION_SKILL_CONTENTS=("TDD skill content" "Testing skill content")

    local user_msg
    user_msg=$(jq -n --arg role "user" --arg content "hello" '{"role": $role, "content": $content}')
    BAISH_SESSION_MESSAGES=("${user_msg}")

    local request
    request=$(baish_session_build_request '[]')

    # Extract all system messages in order
    local system_msgs
    system_msgs=$(echo "${request}" | jq -c '[.messages[] | select(.role == "system") | .content]')

    # First message should be base system prompt
    local first_msg
    first_msg=$(echo "${system_msgs}" | jq -r '.[0]')
    [[ "${first_msg}" == "You are BAISH." ]]

    # Second message should be first skill
    local second_msg
    second_msg=$(echo "${system_msgs}" | jq -r '.[1]')
    [[ "${second_msg}" == "TDD skill content" ]]

    # Third message should be second skill
    local third_msg
    third_msg=$(echo "${system_msgs}" | jq -r '.[2]')
    [[ "${third_msg}" == "Testing skill content" ]]

    # Total system messages: base + 2 skills = 3
    local sys_count
    sys_count=$(echo "${system_msgs}" | jq 'length')
    [[ "${sys_count}" -eq 3 ]]
}

@test "conversation messages appear after skill messages" {
    BAISH_SYSTEM_PROMPT="You are BAISH."
    BAISH_SESSION_SKILL_NAMES=("tdd")
    BAISH_SESSION_SKILL_CONTENTS=("TDD content")

    local user_msg
    user_msg=$(jq -n --arg role "user" --arg content "hello" '{"role": $role, "content": $content}')
    local assistant_msg
    assistant_msg=$(jq -n --arg role "assistant" --arg content "hi" '{"role": $role, "content": $content}')
    BAISH_SESSION_MESSAGES=("${user_msg}" "${assistant_msg}")

    local request
    request=$(baish_session_build_request '[]')

    # The last two messages should be the conversation
    local last_role
    last_role=$(echo "${request}" | jq -r '.messages[-1].role')
    [[ "${last_role}" == "assistant" ]]

    local second_last_role
    second_last_role=$(echo "${request}" | jq -r '.messages[-2].role')
    [[ "${second_last_role}" == "user" ]]
}

# ============================================================
# Integration: /skill:<name> through command dispatch
# ============================================================

@test "/skill:<name> command loads skill via dispatch" {
    local global_dir="${BAISH_STATE_DIR}/home/.baish/skills/tdd"
    mkdir -p "${global_dir}"
    echo "# TDD Skill" > "${global_dir}/SKILL.md"

    baish_dispatch_command "/skill:tdd"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "tdd" ]]
}

@test "/skill:<name> with missing skill returns error" {
    local result
    result=$(baish_dispatch_command "/skill:nonexistent" 2>&1) || true

    [[ "${result}" == *"not found"* || "${result}" == *"Skill"* ]]
}

# ============================================================
# Command palette dispatch equivalence
# ============================================================

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
