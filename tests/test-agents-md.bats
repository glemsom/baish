#!/usr/bin/env bats
# BAISH — Tests: AGENTS.md Loading Module (lib/agent/agents-md.sh)
#
# Covers all edge cases for loading and injecting ~/.baish/AGENTS.md (global)
# and ./AGENTS.md (project):
#   - Both files exist (verify concatenation order)
#   - Only global exists
#   - Only project exists
#   - Neither exists
#   - One file empty, other present
#   - Both files empty
#   - Content survives /new

setup() {
    # Isolate to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    BAISH_DEBUG=0
    export BAISH_DEBUG

    # Create a separate home directory for global AGENTS.md
    BAISH_HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${BAISH_HOME}"
    export HOME="${BAISH_HOME}"

    # Create a project directory inside the temp state dir, and cd into it
    # so ./AGENTS.md resolves inside the temp dir, not the project root
    BAISH_PROJECT_DIR="${BAISH_STATE_DIR}/project"
    mkdir -p "${BAISH_PROJECT_DIR}"
    export BAISH_PROJECT_DIR

    # Remember original PWD and cd into temp project dir
    BAISH_ORIG_PWD="${PWD}"
    cd "${BAISH_PROJECT_DIR}"

    # Reset AGENTS.md content between tests
    BAISH_AGENTS_MD_CONTENT=""

    # Reset session arrays
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_SKILL_NAMES=()
    BAISH_SESSION_SKILL_CONTENTS=()
    BAISH_SESSION_TOOL_ROUNDS=0

    # Clean up any AGENTS.md files left by previous tests
    rm -f "${HOME}/.baish/AGENTS.md"
    rm -f "${BAISH_PROJECT_DIR}/AGENTS.md"

    # Source modules under test
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/agents-md.sh"
}

teardown() {
    # Return to original directory before cleanup
    cd "${BAISH_ORIG_PWD}"
    rm -rf "${BAISH_STATE_DIR}"
}

# --- Helper: create AGENTS.md files ---

create_global_agents_md() {
    local content="$1"
    mkdir -p "${HOME}/.baish"
    printf "%s" "${content}" > "${HOME}/.baish/AGENTS.md"
}

create_project_agents_md() {
    local content="$1"
    printf "%s" "${content}" > "${PWD}/AGENTS.md"
}

# ============================================================
# Both files exist
# ============================================================

@test "AGENTS.md: both global and project exist — global content appears before project content" {
    create_global_agents_md "Global instructions"
    create_project_agents_md "Project instructions"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)

    # Both should be present
    [[ "${content}" == *"Global instructions"* ]]
    [[ "${content}" == *"Project instructions"* ]]

    # Global should come before project
    [[ "$(echo "${content}" | head -1)" == "Global instructions" ]]
}

@test "AGENTS.md: both files exist — separated by blank line" {
    create_global_agents_md "First part"
    create_project_agents_md "Second part"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)

    # Should have a blank line between the two
    [[ "${content}" == "First part"$'\n\n'"Second part" ]]
}

# ============================================================
# Only one file exists
# ============================================================

@test "AGENTS.md: only global exists — injected correctly" {
    create_global_agents_md "Global agent instructions"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Global agent instructions" ]]
}

@test "AGENTS.md: only project exists — injected correctly" {
    create_project_agents_md "Project agent instructions"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Project agent instructions" ]]
}

@test "AGENTS.md: only global exists — injected as user message in build_request" {
    create_global_agents_md "Global instructions"

    baish_agents_md_init

    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "Hello"

    local result
    result=$(baish_session_build_request '[]')

    # Messages: system, skill(system), agents(user), user(conversation) = 4
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 4 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user user " ]]

    local agents_content
    agents_content=$(echo "${result}" | jq -r '.messages[2].content')
    [[ "${agents_content}" == "Global instructions" ]]
}

@test "AGENTS.md: only project exists — injected as user message in build_request" {
    create_project_agents_md "Project instructions"

    baish_agents_md_init

    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "Hello"

    local result
    result=$(baish_session_build_request '[]')

    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 4 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user user " ]]

    local agents_content
    agents_content=$(echo "${result}" | jq -r '.messages[2].content')
    [[ "${agents_content}" == "Project instructions" ]]
}

# ============================================================
# Neither file exists
# ============================================================

@test "AGENTS.md: neither file exists — no content loaded" {
    rm -f "${HOME}/.baish/AGENTS.md"
    rm -f "${PWD}/AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ -z "${content}" ]]
}

@test "AGENTS.md: neither file exists — no user message injected in build_request" {
    rm -f "${HOME}/.baish/AGENTS.md"
    rm -f "${PWD}/AGENTS.md"

    baish_agents_md_init

    # Add some conversation and skills
    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "Hello"

    local result
    result=$(baish_session_build_request '[]')

    # Messages: system, skill(system), user(conversation) = 3 (no extra user for AGENTS.md)
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 3 ]]

    # Roles should be: system, system, user (no extra user for AGENTS.md)
    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user " ]]
}

# ============================================================
# One file empty, other present
# ============================================================

@test "AGENTS.md: global empty, project has content — project content injected" {
    # Global file is empty (0 bytes)
    mkdir -p "${HOME}/.baish"
    touch "${HOME}/.baish/AGENTS.md"
    create_project_agents_md "Project instructions"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Project instructions" ]]
}

@test "AGENTS.md: global has content, project empty — global content injected" {
    create_global_agents_md "Global instructions"
    # Project file is empty (0 bytes)
    touch "${PWD}/AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Global instructions" ]]
}

@test "AGENTS.md: global empty, project has content — only project message injected in build_request" {
    mkdir -p "${HOME}/.baish"
    touch "${HOME}/.baish/AGENTS.md"
    create_project_agents_md "Project only"

    baish_agents_md_init

    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "Hello"

    local result
    result=$(baish_session_build_request '[]')

    # Messages: system, skill(system), agents(user), user(conversation) = 4
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 4 ]]

    # Roles: system, system, user, user
    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user user " ]]

    # The agents user message should have project content
    local agents_content
    agents_content=$(echo "${result}" | jq -r '.messages[2].content')
    [[ "${agents_content}" == "Project only" ]]
}

@test "AGENTS.md: global has content, project empty — only global message injected in build_request" {
    create_global_agents_md "Global only"
    touch "${PWD}/AGENTS.md"

    baish_agents_md_init

    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "Hello"

    local result
    result=$(baish_session_build_request '[]')

    # Messages: system, skill(system), agents(user), user(conversation) = 4
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 4 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user user " ]]

    local agents_content
    agents_content=$(echo "${result}" | jq -r '.messages[2].content')
    [[ "${agents_content}" == "Global only" ]]
}

# ============================================================
# Both files empty
# ============================================================

@test "AGENTS.md: both files empty — no content loaded" {
    mkdir -p "${HOME}/.baish"
    touch "${HOME}/.baish/AGENTS.md"
    touch "${PWD}/AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ -z "${content}" ]]
}

@test "AGENTS.md: both files empty — no user message injected in build_request" {
    mkdir -p "${HOME}/.baish"
    touch "${HOME}/.baish/AGENTS.md"
    touch "${PWD}/AGENTS.md"

    baish_agents_md_init

    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "Hello"

    local result
    result=$(baish_session_build_request '[]')

    # Messages: system, skill(system), user(conversation) = 3 (no extra user for AGENTS.md)
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 3 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user " ]]
}

# ============================================================
# Content survives /new
# ============================================================

@test "AGENTS.md: content survives reset_context_window (simulates /new)" {
    create_global_agents_md "Persistent instructions"

    baish_agents_md_init

    # Verify content is loaded
    local before
    before=$(baish_agents_md_get_content)
    [[ "${before}" == "Persistent instructions" ]]

    # Simulate /new: reset session context
    baish_session_reset_context_window

    # Content should still be available
    local after
    after=$(baish_agents_md_get_content)
    [[ "${after}" == "Persistent instructions" ]]
}

@test "AGENTS.md: content still injected in build_request after /new" {
    create_global_agents_md "Instructions that survive /new"

    baish_agents_md_init

    # Add some conversation before /new
    baish_session_append_user_message "Old message"

    # Simulate /new
    baish_session_reset_context_window

    # Add new conversation after /new
    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are helpful.")
    baish_session_append_user_message "New message"

    local result
    result=$(baish_session_build_request '[]')

    # Messages: system, skill(system), agents(user), user(conversation) = 4
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 4 ]]

    # Roles: system, system, user, user
    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user user " ]]

    # The AGENTS.md user message should be present (between skills and conversation)
    local agents_content
    agents_content=$(echo "${result}" | jq -r '.messages[2].content')
    [[ "${agents_content}" == "Instructions that survive /new" ]]

    # The conversation should only have the new message (old one was cleared by /new)
    local conv_content
    conv_content=$(echo "${result}" | jq -r '.messages[3].content')
    [[ "${conv_content}" == "New message" ]]
    [[ "${conv_content}" != "Old message" ]]
}

@test "AGENTS.md: content survives multiple /new cycles" {
    create_global_agents_md "Always present"

    baish_agents_md_init

    # First /new
    baish_session_reset_context_window
    local content1
    content1=$(baish_agents_md_get_content)
    [[ "${content1}" == "Always present" ]]

    # Second /new
    baish_session_reset_context_window
    local content2
    content2=$(baish_agents_md_get_content)
    [[ "${content2}" == "Always present" ]]

    # Third /new
    baish_session_reset_context_window
    local content3
    content3=$(baish_agents_md_get_content)
    [[ "${content3}" == "Always present" ]]
}

@test "AGENTS.md: content survives /new when both files exist" {
    create_global_agents_md "Global instructions"
    create_project_agents_md "Project instructions"

    baish_agents_md_init

    # Verify both are loaded
    local before
    before=$(baish_agents_md_get_content)
    [[ "${before}" == *"Global instructions"* ]]
    [[ "${before}" == *"Project instructions"* ]]

    # Simulate /new
    baish_session_reset_context_window

    # Both should still be present
    local after
    after=$(baish_agents_md_get_content)
    [[ "${after}" == *"Global instructions"* ]]
    [[ "${after}" == *"Project instructions"* ]]
    [[ "${after}" == "Global instructions"$'\n\n'"Project instructions" ]]
}
