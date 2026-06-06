#!/usr/bin/env bats
# BAISH — Tests: Tool result helpers, schema generation, and dispatcher
#
# Direct unit tests for baish_tool_success_json, baish_tool_error_json,
# baish_tool_schemas, and baish_tool_execute. These functions originally
# lived in lib/tools/engine.sh which was collapsed per ARCH-001:
#   - Helpers + dispatcher → lib/tools/tools.sh
#   - Schema generation   → lib/providers/chat-parser.sh

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/tools/tools.sh"
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"

    # Isolate file operations to a temp directory
    BAISH_LAUNCH_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BAISH_LAUNCH_DIR
    mkdir -p "${BAISH_LAUNCH_DIR}"
}

# ── baish_tool_success_json ─────────────────────────────────────────────

@test "baish_tool_success_json returns ok:true" {
    local result
    result=$(baish_tool_success_json "read" '{"path": "test.txt", "content": "hello", "line_count": 1}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "true" ]]
}

@test "baish_tool_success_json includes tool name" {
    local result
    result=$(baish_tool_success_json "write" '{"path": "out.txt", "bytes_written": 5}')

    local tool
    tool=$(echo "$result" | jq -r '.tool')
    [[ "$tool" == "write" ]]
}

@test "baish_tool_success_json embeds data payload unchanged" {
    local result
    result=$(baish_tool_success_json "bash" '{"stdout": "hello", "exit_code": 0}')

    local data_stdout data_exit_code
    data_stdout=$(echo "$result" | jq -r '.data.stdout')
    data_exit_code=$(echo "$result" | jq -r '.data.exit_code')
    [[ "$data_stdout" == "hello" ]]
    [[ "$data_exit_code" -eq 0 ]]
}

@test "baish_tool_success_json handles empty data JSON" {
    local result
    result=$(baish_tool_success_json "read" '{}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "true" ]]
}

@test "baish_tool_success_json schema has only ok, tool, data fields" {
    local result
    result=$(baish_tool_success_json "bash" '{}')

    local keys
    keys=$(echo "$result" | jq -r 'keys | sort | join(",")')
    [[ "$keys" == "data,ok,tool" ]]
}

# ── baish_tool_error_json ───────────────────────────────────────────────

@test "baish_tool_error_json returns ok:false" {
    local result
    result=$(baish_tool_error_json "read" "FILE_NOT_FOUND" "File not found: test.txt")

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "false" ]]
}

@test "baish_tool_error_json includes tool name" {
    local result
    result=$(baish_tool_error_json "edit" "OLD_TEXT_NOT_FOUND" "oldText not found")

    local tool
    tool=$(echo "$result" | jq -r '.tool')
    [[ "$tool" == "edit" ]]
}

@test "baish_tool_error_json includes error code and message" {
    local result
    result=$(baish_tool_error_json "bash" "MISSING_COMMAND" "The command arg is required")

    local code message
    code=$(echo "$result" | jq -r '.error.code')
    message=$(echo "$result" | jq -r '.error.message')
    [[ "$code" == "MISSING_COMMAND" ]]
    [[ "$message" == "The command arg is required" ]]
}

@test "baish_tool_error_json handles empty message" {
    local result
    result=$(baish_tool_error_json "read" "UNKNOWN_ERROR" "")

    local message
    message=$(echo "$result" | jq -r '.error.message')
    [[ "$message" == "" ]]
}

@test "baish_tool_error_json schema has only ok, tool, error fields" {
    local result
    result=$(baish_tool_error_json "bash" "TIMEOUT" "timed out")

    local keys
    keys=$(echo "$result" | jq -r 'keys | sort | join(",")')
    [[ "$keys" == "error,ok,tool" ]]
}

@test "baish_tool_error_json error object has code and message" {
    local result
    result=$(baish_tool_error_json "read" "PERMISSION_DENIED" "no access")

    local error_keys
    error_keys=$(echo "$result" | jq -r '.error | keys | sort | join(",")')
    [[ "$error_keys" == "code,message" ]]
}

# ── baish_tool_schemas (contract tests) ─────────────────────────────────

@test "baish_tool_schemas validates as valid JSON" {
    local schemas
    schemas=$(baish_tool_schemas)

    echo "$schemas" | jq '.' > /dev/null
}

@test "baish_tool_schemas returns exactly 4 tools" {
    local schemas
    schemas=$(baish_tool_schemas)

    local count
    count=$(echo "$schemas" | jq 'length')
    [[ "$count" -eq 4 ]]
}

@test "baish_tool_schemas tool names are read, write, edit, bash" {
    local schemas
    schemas=$(baish_tool_schemas)

    local names
    names=$(echo "$schemas" | jq -r '[.[].function.name] | sort | join(",")')
    [[ "$names" == "bash,edit,read,write" ]]
}

@test "baish_tool_schemas each tool has type=function" {
    local schemas
    schemas=$(baish_tool_schemas)

    local all_function
    all_function=$(echo "$schemas" | jq '[.[].type == "function"] | all')
    [[ "$all_function" == "true" ]]
}

@test "baish_tool_schemas each tool has non-empty description" {
    local schemas
    schemas=$(baish_tool_schemas)

    local all_desc
    all_desc=$(echo "$schemas" | jq '[.[].function.description | length > 0] | all')
    [[ "$all_desc" == "true" ]]
}

@test "baish_tool_schemas each tool has required field in parameters" {
    local schemas
    schemas=$(baish_tool_schemas)

    local all_required
    all_required=$(echo "$schemas" | jq '[.[].function.parameters | has("required")] | all')
    [[ "$all_required" == "true" ]]
}

@test "baish_tool_schemas read tool requires path" {
    local schemas
    schemas=$(baish_tool_schemas)

    local required
    required=$(echo "$schemas" | jq -r '.[0].function.parameters.required | join(",")')
    [[ "$required" == "path" ]]
}

@test "baish_tool_schemas write tool requires path and content" {
    local schemas
    schemas=$(baish_tool_schemas)

    local required
    required=$(echo "$schemas" | jq -r '.[1].function.parameters.required | sort | join(",")')
    [[ "$required" == "content,path" ]]
}

@test "baish_tool_schemas edit tool requires path and edits" {
    local schemas
    schemas=$(baish_tool_schemas)

    local required
    required=$(echo "$schemas" | jq -r '.[2].function.parameters.required | sort | join(",")')
    [[ "$required" == "edits,path" ]]
}

@test "baish_tool_schemas bash tool requires command" {
    local schemas
    schemas=$(baish_tool_schemas)

    local required
    required=$(echo "$schemas" | jq -r '.[3].function.parameters.required | join(",")')
    [[ "$required" == "command" ]]
}

# ── baish_tool_execute (dispatcher) ─────────────────────────────────────

@test "baish_tool_execute dispatches to read tool" {
    # read on missing file returns structured error, proving dispatch worked
    local result
    result=$(baish_tool_execute "read" '{"path": "/nonexistent/read_test"}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "false" ]]
    [[ "$(echo "$result" | jq -r '.tool')" == "read" ]]
    [[ "$(echo "$result" | jq -r '.error.code')" == "FILE_NOT_FOUND" ]]
}

@test "baish_tool_execute dispatches to write tool" {
    local tmpdir
    tmpdir=$(mktemp -d)
    local result
    result=$(baish_tool_execute "write" "{\"path\": \"${tmpdir}/test.txt\", \"content\": \"hello\"}")

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "true" ]]
    [[ "$(echo "$result" | jq -r '.tool')" == "write" ]]

    # Verify file was actually written
    [[ -f "${tmpdir}/test.txt" ]]
    [[ "$(cat "${tmpdir}/test.txt")" == "hello" ]]
    rm -rf "${tmpdir}"
}

@test "baish_tool_execute dispatches to edit tool" {
    local tmpdir
    tmpdir=$(mktemp -d)
    local filepath="${tmpdir}/edit_test.txt"
    echo "old text here" > "$filepath"

    local result
    result=$(baish_tool_execute "edit" "{\"path\": \"${filepath}\", \"edits\": [{\"oldText\": \"old text here\", \"newText\": \"new text here\"}]}")

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "true" ]]
    [[ "$(echo "$result" | jq -r '.tool')" == "edit" ]]
    [[ "$(cat "$filepath")" == "new text here" ]]
    rm -rf "${tmpdir}"
}

@test "baish_tool_execute dispatches to bash tool" {
    local result
    result=$(baish_tool_execute "bash" '{"command": "echo dispatched"}')

    local ok stdout
    ok=$(echo "$result" | jq -r '.ok')
    stdout=$(echo "$result" | jq -r '.data.stdout')
    [[ "$ok" == "true" ]]
    [[ "$stdout" == "dispatched" ]]
}

@test "baish_tool_execute returns error for unknown tool" {
    local result
    result=$(baish_tool_execute "nonexistent" '{}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')
    [[ "$ok" == "false" ]]
    [[ "$code" == "UNKNOWN_TOOL" ]]
}
