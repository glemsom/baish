#!/usr/bin/env bats
# BAISH — Tests: Skill Loading (lib/agent/skills.sh)

setup() {
    # Isolate to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    BAISH_DEBUG=0
    export BAISH_DEBUG

    # Create a project-like launch directory inside the temp dir
    BAISH_LAUNCH_DIR="${BAISH_STATE_DIR}/project"
    mkdir -p "${BAISH_LAUNCH_DIR}"
    export BAISH_LAUNCH_DIR

    # Create a home directory for user-global skills
    BAISH_HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${BAISH_HOME}"
    export HOME="${BAISH_HOME}"

    # Reset session skill arrays
    BAISH_SESSION_SKILL_NAMES=()
    BAISH_SESSION_SKILL_CONTENTS=()

    # Source modules under test
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/skills.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# --- Helper to create skill files ---

create_project_skill() {
    local name="$1"
    local content="$2"
    local dir="${BAISH_LAUNCH_DIR}/.baish/skills/${name}"
    mkdir -p "${dir}"
    printf "%s" "${content}" > "${dir}/SKILL.md"
}

create_global_skill() {
    local name="$1"
    local content="$2"
    local dir="${HOME}/.baish/skills/${name}"
    mkdir -p "${dir}"
    printf "%s" "${content}" > "${dir}/SKILL.md"
}

# --- baish_skill_resolve ---

@test "baish_skill_resolve returns project-local path when both project-local and user-global exist" {
    create_project_skill "test-skill" "Project-local content"
    create_global_skill "test-skill" "User-global content"

    local result
    result=$(baish_skill_resolve "test-skill")
    local expected="${BAISH_LAUNCH_DIR}/.baish/skills/test-skill/SKILL.md"

    [[ "${result}" == "${expected}" ]]
}

@test "baish_skill_resolve falls back to user-global when project-local does not exist" {
    create_global_skill "my-skill" "Global content"

    local result
    result=$(baish_skill_resolve "my-skill")
    local expected="${HOME}/.baish/skills/my-skill/SKILL.md"

    [[ "${result}" == "${expected}" ]]
}

@test "baish_skill_resolve returns exit 1 when skill is not found in either location" {
    run baish_skill_resolve "nonexistent-skill"

    [[ "${status}" -eq 1 ]]
    [[ -z "${output}" ]]
}

@test "baish_skill_resolve prefers project-local when only project-local exists" {
    create_project_skill "local-only" "Local content"

    local result
    result=$(baish_skill_resolve "local-only")
    local expected="${BAISH_LAUNCH_DIR}/.baish/skills/local-only/SKILL.md"

    [[ "${result}" == "${expected}" ]]
}

@test "baish_skill_resolve returns user-global path when only user-global exists" {
    create_global_skill "global-only" "Global content"

    local result
    result=$(baish_skill_resolve "global-only")
    local expected="${HOME}/.baish/skills/global-only/SKILL.md"

    [[ "${result}" == "${expected}" ]]
}

@test "baish_skill_resolve with custom skills_root overrides BAISH_LAUNCH_DIR" {
    local custom_root="${BAISH_STATE_DIR}/custom"
    mkdir -p "${custom_root}/.baish/skills/custom-skill"
    printf "custom" > "${custom_root}/.baish/skills/custom-skill/SKILL.md"

    local result
    result=$(baish_skill_resolve "custom-skill" "${custom_root}")
    local expected="${custom_root}/.baish/skills/custom-skill/SKILL.md"

    [[ "${result}" == "${expected}" ]]
}

# --- baish_skill_load ---

@test "baish_skill_load reads SKILL.md content and appends to session arrays" {
    create_project_skill "helper" "You are a helpful assistant."

    baish_skill_load "helper"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ ${#BAISH_SESSION_SKILL_CONTENTS[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "helper" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == "You are a helpful assistant." ]]
}

@test "baish_skill_load loads from user-global when project-local does not exist" {
    create_global_skill "coder" "You write code."

    baish_skill_load "coder"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "coder" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == "You write code." ]]
}

@test "baish_skill_load is idempotent — loading the same skill twice is a no-op" {
    create_project_skill "durable" "Load once."

    baish_skill_load "durable"
    baish_skill_load "durable"
    baish_skill_load "durable"

    # Should only be in the arrays once
    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ ${#BAISH_SESSION_SKILL_CONTENTS[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "durable" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == "Load once." ]]
}

@test "baish_skill_load returns 1 and prints an error for empty skill name" {
    run baish_skill_load ""

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *"Skill name is required"* ]]
}

@test "baish_skill_load returns 1 for a non-existent skill name" {
    run baish_skill_load "does-not-exist"

    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *"Skill 'does-not-exist' not found"* ]]
}

@test "baish_skill_load returns 1 for a non-existent skill even when other skills exist" {
    create_project_skill "real" "I exist."

    baish_skill_load "real"
    run baish_skill_load "fake"

    [[ "${status}" -eq 1 ]]
    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "real" ]]
}

@test "baish_skill_load loads multiple different skills" {
    create_project_skill "skill-a" "Content A"
    create_project_skill "skill-b" "Content B"

    baish_skill_load "skill-a"
    baish_skill_load "skill-b"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 2 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "skill-a" ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[1]}" == "skill-b" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == "Content A" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[1]}" == "Content B" ]]
}

@test "baish_skill_load with custom skills_root loads from custom location" {
    local custom_root="${BAISH_STATE_DIR}/custom"
    mkdir -p "${custom_root}/.baish/skills/custom-skill"
    printf "Custom skill content" > "${custom_root}/.baish/skills/custom-skill/SKILL.md"

    baish_skill_load "custom-skill" "${custom_root}"

    [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 1 ]]
    [[ "${BAISH_SESSION_SKILL_NAMES[0]}" == "custom-skill" ]]
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == "Custom skill content" ]]
}

@test "baish_skill_load handles multiline SKILL.md content" {
    local content=$'Line 1\nLine 2\nLine 3'
    create_project_skill "multi" "${content}"

    baish_skill_load "multi"

    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == $'Line 1\nLine 2\nLine 3' ]]
}

@test "baish_skill_load returns 0 on success" {
    create_project_skill "ok" "OK content"

    run baish_skill_load "ok"

    [[ "${status}" -eq 0 ]]
}

@test "baish_skill_load project-local overrides user-global even if loaded first" {
    # Create both project-local and user-global versions
    create_global_skill "override" "Global content"
    create_project_skill "override" "Project content"

    baish_skill_load "override"

    # Should load project content
    [[ "${BAISH_SESSION_SKILL_CONTENTS[0]}" == "Project content" ]]
}
