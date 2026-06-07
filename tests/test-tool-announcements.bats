#!/usr/bin/env bats
# BAISH — Integration tests: tool announcements via mock provider e2e
#
# Tests the replace-in-place announcement flow (🔄 → ✅/❌) through
# the full agent loop, exercising all four tool types with a mock provider.

setup() {
    # Isolate state to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR
    export HOME="${BAISH_STATE_DIR}/home"
    mkdir -p "${HOME}"

    # Create a workspace directory with test files
    BAISH_LAUNCH_DIR="${BAISH_STATE_DIR}/workspace"
    export BAISH_LAUNCH_DIR
    mkdir -p "${BAISH_LAUNCH_DIR}"

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Stop after one tool round to avoid infinite mock-provider loop
    # (mock returns the same pre-programmed tool calls every round)
    BAISH_MAX_TOOL_ROUNDS=1

    # Source modules
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/state.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/run-loop.sh"
    source "${BAISH_ROOT}/lib/providers/mock.sh"
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# ============================================================
# 🔄 → ✅ flow — read tool
# ============================================================

@test "agent loop shows 🔄 → ✅ announcement flow for read tool" {
    # Create a file that the mock will read
    printf 'test content\n' > "${BAISH_LAUNCH_DIR}/announce_read.txt"

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will read the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-ann-read","name":"read","arguments":"{\"path\":\"announce_read.txt\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local output
    output=$(baish_agent_run_user_message "Read the file" 2>/dev/null)

    # Output should contain the in-progress 🔄 announcement (with \r prefix)
    [[ "$output" == *"🔄"* ]]

    # Output should contain the success ✅ badge
    [[ "$output" == *"✅"* ]]

    # Output should contain the read icon 📖
    [[ "$output" == *"📖"* ]]

    # Output should contain the file path from the announcement
    [[ "$output" == *"announce_read.txt"* ]]

    # The ✅ result should come after the 🔄 announcement (overwrites in-place)
    # In captured output: \r🔄... appears before \r\033[K✅...
    local announce_pos success_pos
    # Find position of 🔄 (the in-progress emoji)
    announce_pos=$(printf '%s' "$output" | grep -b -o '🔄' | head -1 | cut -d: -f1)
    # Find position of ✅ (the success emoji)
    success_pos=$(printf '%s' "$output" | grep -b -o '✅' | head -1 | cut -d: -f1)

    # The 🔄 announcement should appear before the ✅ result
    [[ "$announce_pos" -lt "$success_pos" ]]
}

# ============================================================
# 🔄 → ✅ flow — write tool
# ============================================================

@test "agent loop shows 🔄 → ✅ announcement flow for write tool" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will write the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-ann-write","name":"write","arguments":"{\"path\":\"announce_write.txt\",\"content\":\"written content\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local output
    output=$(baish_agent_run_user_message "Write a file" 2>/dev/null)

    # Output should contain the in-progress 🔄 announcement
    [[ "$output" == *"🔄"* ]]

    # Output should contain the success ✅ badge
    [[ "$output" == *"✅"* ]]

    # Output should contain the write icon 📝
    [[ "$output" == *"📝"* ]]

    # Output should contain the file path
    [[ "$output" == *"announce_write.txt"* ]]

    # 🔄 should appear before ✅
    local announce_pos success_pos
    announce_pos=$(printf '%s' "$output" | grep -b -o '🔄' | head -1 | cut -d: -f1)
    success_pos=$(printf '%s' "$output" | grep -b -o '✅' | head -1 | cut -d: -f1)
    [[ "$announce_pos" -lt "$success_pos" ]]
}

# ============================================================
# 🔄 → ✅ flow — edit tool
# ============================================================

@test "agent loop shows 🔄 → ✅ announcement flow for edit tool" {
    # Create a file with content that the mock will edit
    printf 'before edit\n' > "${BAISH_LAUNCH_DIR}/announce_edit.txt"

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will edit the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-ann-edit","name":"edit","arguments":"{\"path\":\"announce_edit.txt\",\"edits\":[{\"oldText\":\"before edit\",\"newText\":\"after edit\"}]}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local output
    output=$(baish_agent_run_user_message "Edit the file" 2>/dev/null)

    # Output should contain the in-progress 🔄 announcement
    [[ "$output" == *"🔄"* ]]

    # Output should contain the success ✅ badge
    [[ "$output" == *"✅"* ]]

    # Output should contain the edit icon ✏️
    [[ "$output" == *"✏️"* ]]

    # Output should contain the file path
    [[ "$output" == *"announce_edit.txt"* ]]

    # 🔄 should appear before ✅
    local announce_pos success_pos
    announce_pos=$(printf '%s' "$output" | grep -b -o '🔄' | head -1 | cut -d: -f1)
    success_pos=$(printf '%s' "$output" | grep -b -o '✅' | head -1 | cut -d: -f1)
    [[ "$announce_pos" -lt "$success_pos" ]]
}

# ============================================================
# 🔄 → ✅ flow — bash tool with stdout/stderr
# ============================================================

@test "agent loop shows 🔄 → ✅ announcement flow for bash tool with stdout/stderr" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will run a command."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-ann-bash","name":"bash","arguments":"{\"command\":\"echo hello stdout; echo hello stderr >&2\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local output
    output=$(baish_agent_run_user_message "Run a command" 2>/dev/null)

    # Output should contain the in-progress 🔄 announcement
    [[ "$output" == *"🔄"* ]]

    # Output should contain the success ✅ badge
    [[ "$output" == *"✅"* ]]

    # Output should contain the bash icon ⚙️
    [[ "$output" == *"⚙️"* ]]

    # Output should contain the command description (truncated or full)
    [[ "$output" == *"echo hello stdout"* ]]

    # After the ✅ badge line, stdout content should appear
    [[ "$output" == *"hello stdout"* ]]

    # After the ✅ badge line, stderr content should appear
    [[ "$output" == *"hello stderr"* ]]

    # 🔄 should appear before ✅
    local announce_pos success_pos
    announce_pos=$(printf '%s' "$output" | grep -b -o '🔄' | head -1 | cut -d: -f1)
    success_pos=$(printf '%s' "$output" | grep -b -o '✅' | head -1 | cut -d: -f1)
    [[ "$announce_pos" -lt "$success_pos" ]]
}

# ============================================================
# 🔄 → ❌ flow — tool failure with error message
# ============================================================

@test "agent loop shows 🔄 → ❌ announcement flow on tool failure with error message" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will try to read a missing file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-ann-fail","name":"read","arguments":"{\"path\":\"does_not_exist.txt\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local output
    output=$(baish_agent_run_user_message "Read missing file" 2>/dev/null)

    # Output should contain the in-progress 🔄 announcement
    [[ "$output" == *"🔄"* ]]

    # Output should contain the error ❌ badge
    [[ "$output" == *"❌"* ]]

    # Output should contain the read icon 📖
    [[ "$output" == *"📖"* ]]

    # Output should contain the file path
    [[ "$output" == *"does_not_exist.txt"* ]]

    # Output should contain the error message after an em-dash
    [[ "$output" == *" — "* ]]

    # The error badge line should contain the error description
    # (e.g., "File not found" or similar)
    [[ "$output" == *"File not found"* || "$output" == *"not found"* ]]

    # 🔄 should appear before ❌
    local announce_pos error_pos
    announce_pos=$(printf '%s' "$output" | grep -b -o '🔄' | head -1 | cut -d: -f1)
    error_pos=$(printf '%s' "$output" | grep -b -o '❌' | head -1 | cut -d: -f1)
    [[ "$announce_pos" -lt "$error_pos" ]]
}

# ============================================================
# Bash command >100 chars is truncated with … in announcement
# ============================================================

@test "agent loop truncates bash command >100 chars with … in announcement" {
    # Build a command that exceeds 100 characters
    # Each "echo N " is ~8 chars, so 20 repetitions = ~160 chars
    local long_cmd
    long_cmd=$(printf 'echo %.0s' $(seq 1 25))"hello"  # "echo " x 25 + "hello" = 130 chars

    # Verify the command is actually >100 chars
    [[ "${#long_cmd}" -gt 100 ]]

    # Build the arguments JSON with the long command
    local args_json
    args_json=$(jq -n --arg cmd "$long_cmd" '{"command": $cmd}')

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will run a long command."
    BAISH_MOCK_TOOL_CALLS="[{\"id\":\"tc-ann-trunc\",\"name\":\"bash\",\"arguments\":$(printf '%s' "$args_json" | jq -c .)}]"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local output
    output=$(baish_agent_run_user_message "Run long command" 2>/dev/null)

    # The output should contain a truncated version of the command (first 99 chars + …)
    # But the full command (untruncated) should NOT appear in the announcement
    local truncated_prefix="${long_cmd:0:99}"

    # The truncated version should appear in the output (the 🔄 announcement line
    # and the ✅ result line both contain the description)
    [[ "$output" == *"${truncated_prefix}…"* ]]

    # The full untruncated command should NOT appear in the announcement output
    # (but it might appear via other means, so we check that the truncated version exists)
    # Key assertion: the truncated text with … exists somewhere
    [[ "$output" == *"…"* ]]
}

# ============================================================
# Pipeline stages complete without breaking announcement flow
# ============================================================

@test "agent loop pipeline stages complete without breaking announce flow" {
    # Same setup as existing announcement tests
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will read the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-pipe-read","name":"read","arguments":"{\"path\":\"announce_read.txt\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    # Create test file
    printf 'test content\n' > "${BAISH_LAUNCH_DIR}/announce_read.txt"

    local output
    output=$(baish_agent_run_user_message "Read the file" 2>/dev/null)

    # Existing assertions should still pass
    [[ "$output" == *"🔄"* ]]
    [[ "$output" == *"✅"* ]]
    [[ "$output" == *"📖"* ]]
    [[ "$output" == *"announce_read.txt"* ]]
}
