#!/usr/bin/env bats
# BAISH — Tests: TAB Completion (lib/ui/completion.sh)

setup() {
    # Isolate to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    BAISH_DEBUG=0
    export BAISH_DEBUG

    # Create a project directory for path completion tests
    TEST_PROJECT_DIR="${BAISH_STATE_DIR}/project"
    mkdir -p "${TEST_PROJECT_DIR}"

    # Create test files and directories
    touch "${TEST_PROJECT_DIR}/file.txt"
    touch "${TEST_PROJECT_DIR}/foobar.txt"
    mkdir -p "${TEST_PROJECT_DIR}/subdir"
    touch "${TEST_PROJECT_DIR}/subdir/nested.txt"
    touch "${TEST_PROJECT_DIR}/subdir/finder.txt"
    mkdir -p "${TEST_PROJECT_DIR}/subdir/deep"
    touch "${TEST_PROJECT_DIR}/subdir/deep/target.txt"

    # Source modules under test
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/ui/completion.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# --- baish_complete_paths ---

@test "baish_complete_paths completes file names from a prefix" {
    run baish_complete_paths "fi" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "file.txt" ]]
}

@test "baish_complete_paths completes file names from a prefix with multiple matches" {
    run baish_complete_paths "f" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    # Should match file.txt and foobar.txt
    [[ "${#lines[@]}" -eq 2 ]]
}

@test "baish_complete_paths adds trailing / for directory completions" {
    run baish_complete_paths "sub" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "subdir/" ]]
}

@test "baish_complete_paths handles nested directory paths" {
    run baish_complete_paths "subdir/fi" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "subdir/finder.txt" ]]
}

@test "baish_complete_paths returns nothing for a non-matching prefix" {
    run baish_complete_paths "zzz" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_paths returns directory with trailing / when prefix ends with /" {
    run baish_complete_paths "subdir/" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    # Should list contents of subdir: nested.txt, finder.txt, deep/
    local count
    count=$(echo "${output}" | grep -c .)
    [[ "${count}" -eq 3 ]]
    [[ "${output}" == *"subdir/nested.txt"* ]]
    [[ "${output}" == *"subdir/finder.txt"* ]]
    [[ "${output}" == *"subdir/deep/"* ]]
}

@test "baish_complete_paths handles nonexistent search directory" {
    run baish_complete_paths "nonexistent/fi" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_paths returns directory with trailing / for nested dirs" {
    run baish_complete_paths "subdir/de" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "subdir/deep/" ]]
}

@test "baish_complete_paths returns empty for empty prefix" {
    run baish_complete_paths "" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    # Should list all entries in the directory
    [[ "${#lines[@]}" -gt 0 ]]
    local count
    count=$(echo "${output}" | grep -c .)
    [[ "${count}" -eq 3 ]]  # file.txt, foobar.txt, subdir/
}

# --- baish_complete_commands_stdout ---

@test "baish_complete_commands_stdout matches /-prefixed commands" {
    run baish_complete_commands_stdout "/q"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "/quit" ]]
}

@test "baish_complete_commands_stdout matches multiple commands with common prefix" {
    run baish_complete_commands_stdout "/"

    [[ "${status}" -eq 0 ]]
    # Should return all registered commands
    [[ "${#lines[@]}" -eq 7 ]]
}

@test "baish_complete_commands_stdout returns nothing for unknown prefix" {
    run baish_complete_commands_stdout "/xyz"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_commands_stdout matches exact command" {
    run baish_complete_commands_stdout "/quit"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "/quit" ]]
}

@test "baish_complete_commands_stdout matches /skill: prefix against loaded skill names" {
    # Load some skills
    BAISH_SESSION_SKILL_NAMES=("python-helper" "code-reviewer" "debugger")

    run baish_complete_commands_stdout "/skill:py"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "/skill:python-helper" ]]
}

@test "baish_complete_commands_stdout matches multiple skills with /skill: prefix" {
    BAISH_SESSION_SKILL_NAMES=("python-helper" "python-linter" "debugger")

    run baish_complete_commands_stdout "/skill:py"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 2 ]]
    [[ "${lines[0]}" == "/skill:python-helper" ]]
    [[ "${lines[1]}" == "/skill:python-linter" ]]
}

@test "baish_complete_commands_stdout returns nothing for /skill: prefix with no matching skills" {
    BAISH_SESSION_SKILL_NAMES=("helper" "linter")

    run baish_complete_commands_stdout "/skill:py"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_commands_stdout returns nothing for /skill: prefix when no skills are loaded" {
    BAISH_SESSION_SKILL_NAMES=()

    run baish_complete_commands_stdout "/skill:"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_commands_stdout matches /skill: with empty prefix lists all skills" {
    BAISH_SESSION_SKILL_NAMES=("helper" "coder")

    run baish_complete_commands_stdout "/skill:"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 2 ]]
    [[ "${lines[0]}" == "/skill:helper" ]]
    [[ "${lines[1]}" == "/skill:coder" ]]
}

# --- baish_complete_input ---

@test "baish_complete_input completes @-prefixed paths" {
    run baish_complete_input "@fi" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "@file.txt" ]]
}

@test "baish_complete_input completes /-prefixed commands" {
    run baish_complete_input "/q" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 1 ]]
    [[ "${lines[0]}" == "/quit" ]]
}

@test "baish_complete_input returns nothing for /skill: prefix with no skills" {
    BAISH_SESSION_SKILL_NAMES=()

    run baish_complete_input "/skill:py" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_input returns nothing for non-@ and non-/ prefixes" {
    run baish_complete_input "plaintext" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_input returns nothing for empty string" {
    run baish_complete_input "" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    [[ "${#lines[@]}" -eq 0 ]]
}

@test "baish_complete_input handles @ alone (no prefix)" {
    run baish_complete_input "@" "${TEST_PROJECT_DIR}"

    [[ "${status}" -eq 0 ]]
    # Should list all project entries with @ prefix
    [[ "${#lines[@]}" -gt 0 ]]
    [[ "${lines[0]}" == @* ]]
}
