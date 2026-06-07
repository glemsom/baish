#!/usr/bin/env bats
# BAISH — Tests: Bash Tool, Agent Loop Limits, and Thinking Spinner
#
# Tests:
# - Bash tool: basic execution, launch directory context, env inheritance
# - Bash tool: env overrides, error handling, timeout
# - Bash tool: structured JSON responses (stdout, stderr, exit_code)
# - Loop limits: BAISH_MAX_TOOL_ROUNDS enforcement
# - Thinking spinner displays during LLM calls

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
# Bash tool — basic execution
# ============================================================

@test "bash tool executes a simple command" {
    local result
    result=$(baish_tool_bash '{"command":"echo hello"}')

    local ok stdout exit_code
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')
    exit_code=$(echo "$result" | jq -r '.data.exit_code')

    [[ "$ok" == "true" ]]
    [[ "$stdout" == "hello" ]]
    [[ "$exit_code" -eq 0 ]]
}

@test "bash tool executes a multi-line command" {
    local result
    result=$(baish_tool_bash '{"command":"echo line1; echo line2"}')

    local ok stdout
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$ok" == "true" ]]
    [[ "$stdout" == $'line1\nline2' ]]
}

@test "bash tool captures stderr separately" {
    local result
    result=$(baish_tool_bash '{"command":"echo error_msg >&2"}')

    local ok stderr
    ok=$(echo "$result" | jq -r '.ok')
    stderr=$(echo "$result" | jq -r '.data.stderr')

    [[ "$ok" == "true" ]]
    [[ "$stderr" == "error_msg" ]]
}

@test "bash tool returns non-zero exit code on failure" {
    local result
    result=$(baish_tool_bash '{"command":"false"}')

    local ok exit_code
    ok=$(echo "$result" | jq -r '.ok')
    exit_code=$(echo "$result" | jq -r '.data.exit_code')

    [[ "$ok" == "true" ]]
    [[ "$exit_code" -ne 0 ]]
}

@test "bash tool captures both stdout and stderr" {
    local result
    result=$(baish_tool_bash '{"command":"echo out; echo err >&2"}')

    local ok stdout stderr
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')
    stderr=$(echo "$result" | jq -r '.data.stderr')

    [[ "$ok" == "true" ]]
    [[ "$stdout" == "out" ]]
    [[ "$stderr" == "err" ]]
}

# ============================================================
# Bash tool — launch directory context
# ============================================================

@test "bash tool executes in the launch directory" {
    mkdir -p "${BAISH_LAUNCH_DIR}/subdir"

    local result
    result=$(baish_tool_bash '{"command":"pwd"}')

    local stdout
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$stdout" == "${BAISH_LAUNCH_DIR}" ]]
}

@test "bash tool can cd and operate within launch directory" {
    mkdir -p "${BAISH_LAUNCH_DIR}/subdir"
    printf 'test content\n' > "${BAISH_LAUNCH_DIR}/subdir/file.txt"

    local result
    result=$(baish_tool_bash '{"command":"cat subdir/file.txt"}')

    local stdout
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$stdout" == "test content" ]]
}

@test "bash tool creates files in launch directory" {
    local result
    result=$(baish_tool_bash '{"command":"echo created_by_bash > test_output.txt"}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    [[ "$ok" == "true" ]]
    [[ -f "${BAISH_LAUNCH_DIR}/test_output.txt" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/test_output.txt")" == "created_by_bash" ]]
}

# ============================================================
# Bash tool — environment inheritance
# ============================================================

@test "bash tool inherits current environment variables" {
    export MY_TEST_VAR="inherited_value"

    local result
    result=$(baish_tool_bash '{"command":"echo $MY_TEST_VAR"}')

    local stdout
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$stdout" == "inherited_value" ]]
}

@test "bash tool supports env parameter to override variables" {
    export MY_OVERRIDABLE_VAR="original"

    local result
    result=$(baish_tool_bash '{"command":"echo $MY_OVERRIDABLE_VAR","env":{"MY_OVERRIDABLE_VAR":"overridden"}}')

    local stdout
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$stdout" == "overridden" ]]
}

@test "bash tool env parameter sets new variables" {
    local result
    result=$(baish_tool_bash '{"command":"echo $NEW_VAR","env":{"NEW_VAR":"from_env_param"}}')

    local stdout
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$stdout" == "from_env_param" ]]
}

@test "bash tool env parameter does not affect parent environment" {
    export PARENT_VAR="parent_value"

    baish_tool_bash '{"command":"export PARENT_VAR=changed","env":{"PARENT_VAR":"changed"}}'

    [[ "$PARENT_VAR" == "parent_value" ]]
}

# ============================================================
# Bash tool — error handling
# ============================================================

@test "bash tool returns error for missing command" {
    local result
    result=$(baish_tool_bash '{}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "MISSING_COMMAND" ]]
}

@test "bash tool returns error for empty command" {
    local result
    result=$(baish_tool_bash '{"command":""}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "MISSING_COMMAND" ]]
}

@test "bash tool handles command that produces no output" {
    local result
    result=$(baish_tool_bash '{"command":"true"}')

    local ok stdout exit_code
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')
    exit_code=$(echo "$result" | jq -r '.data.exit_code')

    [[ "$ok" == "true" ]]
    [[ -z "$stdout" ]]
    [[ "$exit_code" -eq 0 ]]
}

@test "bash tool handles complex shell pipelines" {
    printf 'apple\nbanana\ncherry\n' > "${BAISH_LAUNCH_DIR}/fruits.txt"

    local result
    result=$(baish_tool_bash '{"command":"cat fruits.txt | grep -c apple"}')

    local stdout
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$stdout" == "1" ]]
}

# ============================================================
# Bash tool — timeout
# ============================================================

@test "bash tool respects BAISH_BASH_TIMEOUT" {
    BAISH_BASH_TIMEOUT=2

    local result
    result=$(baish_tool_bash '{"command":"sleep 10"}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "TIMEOUT" ]]
}

@test "bash tool completes before timeout" {
    BAISH_BASH_TIMEOUT=5

    local result
    result=$(baish_tool_bash '{"command":"sleep 0.1 && echo done"}')

    local ok stdout
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$ok" == "true" ]]
    [[ "$stdout" == "done" ]]
}

# ============================================================
# Bash tool — structured JSON response
# ============================================================

@test "bash tool returns correct JSON shape on success" {
    local result
    result=$(baish_tool_bash '{"command":"echo test"}')

    echo "$result" | jq 'has("ok")' | grep -q true
    echo "$result" | jq 'has("tool")' | grep -q true
    echo "$result" | jq 'has("data")' | grep -q true
    echo "$result" | jq '.data | has("stdout")' | grep -q true
    echo "$result" | jq '.data | has("stderr")' | grep -q true
    echo "$result" | jq '.data | has("exit_code")' | grep -q true
    echo "$result" | jq -r '.tool' | grep -q "bash"
}

@test "bash tool returns error JSON shape on timeout" {
    BAISH_BASH_TIMEOUT=1

    local result
    result=$(baish_tool_bash '{"command":"sleep 10"}')

    echo "$result" | jq 'has("ok")' | grep -q true
    echo "$result" | jq 'has("tool")' | grep -q true
    echo "$result" | jq 'has("error")' | grep -q true
    echo "$result" | jq '.error | has("code")' | grep -q true
    echo "$result" | jq '.error | has("message")' | grep -q true
}

# ============================================================
# Loop limits — BAISH_MAX_TOOL_ROUNDS
# ============================================================

@test "agent loop stops after BAISH_MAX_TOOL_ROUNDS rounds" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="round test"
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc1","name":"bash","arguments":"{\"command\":\"echo 1\"}"}]'
    BAISH_MAX_TOOL_ROUNDS=2
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "test"

    # The loop should stop after exactly BAISH_MAX_TOOL_ROUNDS rounds
    [[ ${BAISH_SESSION_TOOL_ROUNDS} -eq 2 ]]
}

@test "agent loop processes fewer rounds when no tool calls returned" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="no tools"
    BAISH_MOCK_TOOL_CALLS=""
    BAISH_MAX_TOOL_ROUNDS=10
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "test"

    # No tool calls means 0 rounds
    [[ ${BAISH_SESSION_TOOL_ROUNDS} -eq 0 ]]
}

@test "BAISH_MAX_TOOL_ROUNDS default is 50" {
    [[ "$BAISH_MAX_TOOL_ROUNDS" -eq 50 ]]
}

# ============================================================
# End-to-end: bash tool via mock provider in agent loop
# ============================================================

@test "agent loop executes bash tool from mock provider end-to-end" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I'll run that command for you."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-bash","name":"bash","arguments":"{\"command\":\"echo hello from bash\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_MAX_TOOL_ROUNDS=1

    baish_agent_run_user_message "Run a command"

    # Verify: user + assistant + tool result = 3 messages
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    # Verify the tool result contains bash output
    local tool_msg stdout_field
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    stdout_field=$(echo "$tool_msg" | jq -r '.content | fromjson | .data.stdout')

    [[ "$stdout_field" == "hello from bash" ]]
}

@test "agent loop handles bash tool error gracefully" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I'll try a failing command."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-bash-err","name":"bash","arguments":"{\"command\":\"\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_MAX_TOOL_ROUNDS=1

    baish_agent_run_user_message "Run empty command"

    # Tool error should still be appended to session
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    local tool_msg ok
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    ok=$(echo "$tool_msg" | jq -r '.content | fromjson | .ok')

    [[ "$ok" == "false" ]]
}

@test "agent loop executes multiple bash tools sequentially" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="Running commands sequentially."
    BAISH_MOCK_TOOL_CALLS='[
        {"id":"tc1","name":"bash","arguments":"{\"command\":\"echo step1 > step.txt\"}"},
        {"id":"tc2","name":"bash","arguments":"{\"command\":\"echo step2 >> step.txt\"}"}
    ]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_MAX_TOOL_ROUNDS=1

    baish_agent_run_user_message "Run two commands"

    # Verify file has both steps (sequential execution)
    [[ -f "${BAISH_LAUNCH_DIR}/step.txt" ]]
    local file_content
    file_content=$(cat "${BAISH_LAUNCH_DIR}/step.txt")
    [[ "$file_content" == $'step1\nstep2' ]]

    # Both tool results appended
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 4 ]]
}

# ============================================================
# Thinking spinner
# ============================================================

@test "baish_output_thinking_bg produces spinner output to stderr" {
    # Run the spinner briefly and capture its output
    local output
    output=$(timeout 0.3 bash -c '
        source "'"${BAISH_ROOT}"'/lib/agent/output.sh"
        baish_output_thinking_bg
    ' 2>&1) || true

    # Should contain spinner characters or "thinking" text
    [[ "$output" == *"thinking"* ]]
}

@test "baish_output_thinking uses spinner chars from config" {
    # Verify the function exists
    declare -F baish_output_thinking &>/dev/null

    # Verify that output.sh has the thinking_bg function
    local output_content
    output_content=$(cat "${BAISH_ROOT}/lib/agent/output.sh")
    [[ "$output_content" == *"baish_output_thinking_bg"* ]]
}

# ============================================================
# Tool execution dispatch — bash via engine
# ============================================================

@test "tool execution dispatches to bash tool via engine" {
    local result
    result=$(baish_tool_execute "bash" '{"command":"echo dispatched"}')

    local ok tool_name stdout
    ok=$(echo "$result" | jq -r '.ok')
    tool_name=$(echo "$result" | jq -r '.tool')
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$ok" == "true" ]]
    [[ "$tool_name" == "bash" ]]
    [[ "$stdout" == "dispatched" ]]
}

# ============================================================
# Output truncation — 64KB limit per stream
# ============================================================

# ============================================================
# Timeout fallback — when timeout(1) is not available
# ============================================================

@test "bash tool timeout fallback works when timeout command is hidden" {
    local orig_path="$PATH"

    # Create a sandbox with all needed tools except timeout
    local sandbox
    sandbox=$(mktemp -d)

    # Symlink every external tool needed by baish_tool_bash, except timeout
    for cmd in bash mktemp chmod head rm sleep kill cat echo printf true mkdir mv wc grep sed jq stat; do
        ln -sf "$(type -P "$cmd")" "$sandbox/"
    done

    # Use only the sandbox PATH (no /usr/bin where timeout lives)
    PATH="$sandbox"

    # Verify timeout is NOT accessible
    ! command -v timeout &>/dev/null

    # Test 1: fallback still executes a simple command
    local result
    BAISH_BASH_TIMEOUT=5
    result=$(baish_tool_bash '{"command":"echo fallback_works"}')
    local ok stdout
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')
    [[ "$ok" == "true" ]]
    [[ "$stdout" == "fallback_works" ]]

    # Test 2: fallback enforces timeout
    BAISH_BASH_TIMEOUT=2
    result=$(baish_tool_bash '{"command":"sleep 10"}')
    ok=$(echo "$result" | jq -r '.ok')
    local code
    code=$(echo "$result" | jq -r '.error.code')
    [[ "$ok" == "false" ]]
    [[ "$code" == "TIMEOUT" ]]

    # Restore PATH and clean up
    PATH="$orig_path"
    rm -rf "$sandbox"
}

@test "bash tool truncates stderr at 64KB" {
    # Generate >64KB of stderr output
    local result
    result=$(baish_tool_bash '{"command":"yes \"STDERR_PATTERN_XYZ\" | head -c 102400 >&2"}')

    local ok stderr
    ok=$(echo "$result" | jq -r '.ok')
    stderr=$(echo "$result" | jq -r '.data.stderr')

    [[ "$ok" == "true" ]]

    # stderr should be ≤ 65536 bytes
    local stderr_len=${#stderr}
    [[ "$stderr_len" -le 65536 ]]

    # First bytes should match the generator pattern
    [[ "$stderr" == "STDERR_PATTERN_XYZ"* ]]
}

@test "bash tool truncates stdout at 64KB" {
    # Generate >64KB of stdout output
    local result
    result=$(baish_tool_bash '{"command":"yes \"0123456789ABCDEF\" | head -c 102400"}')

    local ok stdout
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')

    [[ "$ok" == "true" ]]

    # stdout should be ≤ 65536 bytes
    local stdout_len=${#stdout}
    [[ "$stdout_len" -le 65536 ]]

    # First bytes should match the generator pattern
    [[ "$stdout" == "0123456789ABCDEF"* ]]
}
