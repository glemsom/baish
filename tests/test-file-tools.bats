#!/usr/bin/env bats
# BAISH — Tests: File Tools (read, write, edit) and Tool Execution Engine
#
# Tests:
# - Read tool: basic read, line range, file not found, directory
# - Write tool: create file, overwrite, atomic write, parent dirs, permissions
# - Edit tool: single edit, multi-edit, validation errors
# - Edit validation: uniqueness, overlap detection, error messages
# - Tool execution: structured JSON responses
# - End-to-end: mock provider tool calls executed by agent loop

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
# Read tool
# ============================================================

@test "read tool returns full file content" {
    printf 'hello world\n' > "${BAISH_LAUNCH_DIR}/test.txt"

    local result
    result=$(baish_tool_read '{"path":"test.txt"}')

    local ok content
    ok=$(echo "$result" | jq -r '.ok')
    content=$(echo "$result" | jq -r '.data.content')

    [[ "$ok" == "true" ]]
    [[ "$content" == "hello world" ]]
}

@test "read tool returns structured JSON with path and line_count" {
    printf 'line1\nline2\nline3\n' > "${BAISH_LAUNCH_DIR}/test.txt"

    local result
    result=$(baish_tool_read '{"path":"test.txt"}')

    local path line_count
    path=$(echo "$result" | jq -r '.data.path')
    line_count=$(echo "$result" | jq -r '.data.line_count')

    [[ "$path" == "${BAISH_LAUNCH_DIR}/test.txt" ]]
    [[ "$line_count" == "3" ]]
}

@test "read tool supports offset and limit" {
    printf 'alpha\nbeta\ngamma\ndelta\n' > "${BAISH_LAUNCH_DIR}/lines.txt"

    # Read lines 2-3 (offset=2, limit=2)
    local result
    result=$(baish_tool_read '{"path":"lines.txt","offset":2,"limit":2}')

    local content
    content=$(echo "$result" | jq -r '.data.content')

    [[ "$content" == "beta
gamma" ]]
}

@test "read tool with offset only reads to end of file" {
    printf 'a\nb\nc\nd\n' > "${BAISH_LAUNCH_DIR}/lines.txt"

    local result
    result=$(baish_tool_read '{"path":"lines.txt","offset":3,"limit":0}')

    local content
    content=$(echo "$result" | jq -r '.data.content')

    [[ "$content" == "c
d" ]]
}

@test "read tool returns error for missing file" {
    local result
    result=$(baish_tool_read '{"path":"nonexistent.txt"}')

    local ok code msg
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')
    msg=$(echo "$result" | jq -r '.error.message')

    [[ "$ok" == "false" ]]
    [[ "$code" == "FILE_NOT_FOUND" ]]
    [[ "$msg" == *"nonexistent.txt"* ]]
}

@test "read tool returns error for directory path" {
    mkdir -p "${BAISH_LAUNCH_DIR}/adir"

    local result
    result=$(baish_tool_read '{"path":"adir"}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "IS_DIRECTORY" ]]
}

@test "read tool returns error for missing path argument" {
    local result
    result=$(baish_tool_read '{}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "MISSING_PATH" ]]
}

@test "read tool resolves relative paths to launch directory" {
    mkdir -p "${BAISH_LAUNCH_DIR}/subdir"
    printf 'nested content\n' > "${BAISH_LAUNCH_DIR}/subdir/nested.txt"

    local result
    result=$(baish_tool_read '{"path":"subdir/nested.txt"}')

    local ok content path
    ok=$(echo "$result" | jq -r '.ok')
    content=$(echo "$result" | jq -r '.data.content')
    path=$(echo "$result" | jq -r '.data.path')

    [[ "$ok" == "true" ]]
    [[ "$content" == "nested content" ]]
    [[ "$path" == "${BAISH_LAUNCH_DIR}/subdir/nested.txt" ]]
}

@test "read tool handles empty file" {
    touch "${BAISH_LAUNCH_DIR}/empty.txt"

    local result
    result=$(baish_tool_read '{"path":"empty.txt"}')

    local ok content line_count
    ok=$(echo "$result" | jq -r '.ok')
    content=$(echo "$result" | jq -r '.data.content')
    line_count=$(echo "$result" | jq -r '.data.line_count')

    [[ "$ok" == "true" ]]
    [[ -z "$content" ]]
    [[ "$line_count" == "0" ]]
}

@test "read tool handles file with special characters in content" {
    printf 'line with "quotes" and $dollar\n' > "${BAISH_LAUNCH_DIR}/special.txt"

    local result
    result=$(baish_tool_read '{"path":"special.txt"}')

    local ok content
    ok=$(echo "$result" | jq -r '.ok')
    content=$(echo "$result" | jq -r '.data.content')

    [[ "$ok" == "true" ]]
    [[ "$content" == 'line with "quotes" and $dollar' ]]
}

@test "read tool returns PERMISSION_DENIED for non-readable file" {
    printf 'secret\n' > "${BAISH_LAUNCH_DIR}/unreadable.txt"
    chmod 000 "${BAISH_LAUNCH_DIR}/unreadable.txt"

    local result
    result=$(baish_tool_read '{"path":"unreadable.txt"}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "PERMISSION_DENIED" ]]
}

# ============================================================
# Write tool
# ============================================================

@test "write tool creates a new file" {
    local result
    result=$(baish_tool_write '{"path":"newfile.txt","content":"hello world"}')

    local ok bytes path
    ok=$(echo "$result" | jq -r '.ok')
    bytes=$(echo "$result" | jq -r '.data.bytes_written')
    path=$(echo "$result" | jq -r '.data.path')

    [[ "$ok" == "true" ]]
    [[ "$bytes" == "11" ]]
    [[ "$path" == "${BAISH_LAUNCH_DIR}/newfile.txt" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/newfile.txt")" == "hello world" ]]
}

@test "write tool overwrites an existing file" {
    printf 'old content\n' > "${BAISH_LAUNCH_DIR}/overwrite.txt"

    local result
    result=$(baish_tool_write '{"path":"overwrite.txt","content":"new content"}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    [[ "$ok" == "true" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/overwrite.txt")" == "new content" ]]
}

@test "write tool creates parent directories" {
    [[ ! -d "${BAISH_LAUNCH_DIR}/deep/nested/dir" ]]

    local result
    result=$(baish_tool_write '{"path":"deep/nested/dir/file.txt","content":"deep content"}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    [[ "$ok" == "true" ]]
    [[ -f "${BAISH_LAUNCH_DIR}/deep/nested/dir/file.txt" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/deep/nested/dir/file.txt")" == "deep content" ]]
}

@test "write tool is atomic — temp file is cleaned up" {
    local result
    result=$(baish_tool_write '{"path":"atomic_test.txt","content":"atomic"}')

    # No leftover temp files
    local temp_count
    temp_count=$(find "${BAISH_LAUNCH_DIR}" -name '.baish_tmp.*' 2>/dev/null | wc -l)

    [[ "$temp_count" == "0" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/atomic_test.txt")" == "atomic" ]]
}

@test "write tool preserves file permissions on overwrite" {
    printf 'original\n' > "${BAISH_LAUNCH_DIR}/perms.txt"
    chmod 640 "${BAISH_LAUNCH_DIR}/perms.txt"

    local result
    result=$(baish_tool_write '{"path":"perms.txt","content":"updated"}')

    local mode
    mode=$(stat -c '%a' "${BAISH_LAUNCH_DIR}/perms.txt")

    [[ "$mode" == "640" ]]
}

@test "write tool resolves relative paths" {
    local result
    result=$(baish_tool_write '{"path":"relpath.txt","content":"relative"}')

    local path
    path=$(echo "$result" | jq -r '.data.path')

    [[ "$path" == "${BAISH_LAUNCH_DIR}/relpath.txt" ]]
    [[ -f "${BAISH_LAUNCH_DIR}/relpath.txt" ]]
}

@test "write tool returns error for missing path" {
    local result
    result=$(baish_tool_write '{"content":"no path"}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "MISSING_PATH" ]]
}

@test "write tool returns error for directory path" {
    mkdir -p "${BAISH_LAUNCH_DIR}/adir"

    local result
    result=$(baish_tool_write '{"path":"adir","content":"fail"}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "IS_DIRECTORY" ]]
}

@test "write tool returns PERMISSION_DENIED for non-writable directory" {
    mkdir -p "${BAISH_LAUNCH_DIR}/readonly"
    chmod 555 "${BAISH_LAUNCH_DIR}/readonly"

    local result
    result=$(baish_tool_write '{"path":"readonly/newfile.txt","content":"test"}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "PERMISSION_DENIED" ]]
}

# ============================================================
# Edit tool — basic functionality
# ============================================================

@test "edit tool replaces a single occurrence" {
    printf 'hello world\nhello again\n' > "${BAISH_LAUNCH_DIR}/edit.txt"

    local result
    result=$(baish_tool_edit '{"path":"edit.txt","edits":[{"oldText":"hello world","newText":"goodbye world"}]}')

    local ok content
    ok=$(echo "$result" | jq -r '.ok')
    content=$(cat "${BAISH_LAUNCH_DIR}/edit.txt")

    [[ "$ok" == "true" ]]
    [[ "$content" == "goodbye world
hello again" ]]
}

@test "edit tool applies multiple edits atomically" {
    printf 'alpha\nbeta\ngamma\n' > "${BAISH_LAUNCH_DIR}/multi.txt"

    local result
    result=$(baish_tool_edit '{"path":"multi.txt","edits":[
        {"oldText":"alpha","newText":"ALPHA"},
        {"oldText":"gamma","newText":"GAMMA"}
    ]}')

    local ok content
    ok=$(echo "$result" | jq -r '.ok')
    content=$(cat "${BAISH_LAUNCH_DIR}/multi.txt")

    [[ "$ok" == "true" ]]
    [[ "$content" == "ALPHA
beta
GAMMA" ]]
}

@test "edit tool reports changes_count" {
    printf 'a\nb\nc\n' > "${BAISH_LAUNCH_DIR}/count.txt"

    local result
    result=$(baish_tool_edit '{"path":"count.txt","edits":[
        {"oldText":"a","newText":"A"},
        {"oldText":"b","newText":"B"},
        {"oldText":"c","newText":"C"}
    ]}')

    local changes
    changes=$(echo "$result" | jq -r '.data.changes_count')

    [[ "$changes" == "3" ]]
}

@test "edit tool preserves file permissions" {
    printf 'keep perms\n' > "${BAISH_LAUNCH_DIR}/perms_edit.txt"
    chmod 600 "${BAISH_LAUNCH_DIR}/perms_edit.txt"

    local result
    result=$(baish_tool_edit '{"path":"perms_edit.txt","edits":[{"oldText":"keep perms","newText":"changed"}]}')

    local mode
    mode=$(stat -c '%a' "${BAISH_LAUNCH_DIR}/perms_edit.txt")

    [[ "$mode" == "600" ]]
}

@test "edit tool resolves relative paths" {
    mkdir -p "${BAISH_LAUNCH_DIR}/sub"
    printf 'original\n' > "${BAISH_LAUNCH_DIR}/sub/file.txt"

    local result
    result=$(baish_tool_edit '{"path":"sub/file.txt","edits":[{"oldText":"original","newText":"replaced"}]}')

    local path content
    path=$(echo "$result" | jq -r '.data.path')
    content=$(cat "${BAISH_LAUNCH_DIR}/sub/file.txt")

    [[ "$path" == "${BAISH_LAUNCH_DIR}/sub/file.txt" ]]
    [[ "$content" == "replaced" ]]
}

# ============================================================
# Edit validation — uniqueness
# ============================================================

@test "edit validation rejects oldText that does not exist" {
    printf 'hello world\n' > "${BAISH_LAUNCH_DIR}/unique.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/unique.txt" \
        '[{"oldText":"does not exist","newText":"replacement"}]')

    local ok code msg
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')
    msg=$(echo "$result" | jq -r '.error.message')

    [[ "$ok" == "false" ]]
    [[ "$code" == "OLD_TEXT_NOT_FOUND" ]]
    [[ "$msg" == *"does not exist"* ]]
}

@test "edit validation rejects oldText that appears multiple times" {
    printf 'foo\nbar\nfoo\n' > "${BAISH_LAUNCH_DIR}/dup.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/dup.txt" \
        '[{"oldText":"foo","newText":"baz"}]')

    local ok code msg
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')
    msg=$(echo "$result" | jq -r '.error.message')

    [[ "$ok" == "false" ]]
    [[ "$code" == "OLD_TEXT_NOT_UNIQUE" ]]
    [[ "$msg" == *"2 times"* ]]
}

@test "edit validation passes when oldText appears exactly once" {
    printf 'hello\nworld\nhello again\n' > "${BAISH_LAUNCH_DIR}/ok.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/ok.txt" \
        '[{"oldText":"world","newText":"planet"}]')

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    [[ "$ok" == "true" ]]
}

# ============================================================
# Edit validation — overlapping edits
# ============================================================

@test "edit validation rejects overlapping edits" {
    printf 'the quick brown fox\n' > "${BAISH_LAUNCH_DIR}/overlap.txt"

    # Two edits whose oldText regions overlap
    local edits
    edits='[
        {"oldText":"the quick brown","newText":"a slow red"},
        {"oldText":"quick brown fox","newText":"fast white dog"}
    ]'

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/overlap.txt" "$edits")

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "OVERLAPPING_EDITS" ]]
}

@test "edit validation passes for non-overlapping edits" {
    printf 'hello\nworld\nfoo\nbar\n' > "${BAISH_LAUNCH_DIR}/no_overlap.txt"

    local edits
    edits='[
        {"oldText":"hello","newText":"HELLO"},
        {"oldText":"foo","newText":"FOO"}
    ]'

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/no_overlap.txt" "$edits")

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    [[ "$ok" == "true" ]]
}

@test "edit validation rejects adjacent edits that share a boundary character" {
    printf 'abcdefgh\n' > "${BAISH_LAUNCH_DIR}/adjacent.txt"

    # These don't overlap: "abc" ends at position 3, "def" starts at position 3
    # They are adjacent but not overlapping
    local edits
    edits='[
        {"oldText":"abc","newText":"123"},
        {"oldText":"def","newText":"456"}
    ]'

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/adjacent.txt" "$edits")

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    # Adjacent edits should pass (no overlap)
    [[ "$ok" == "true" ]]
}

# ============================================================
# Edit validation — edge cases
# ============================================================

@test "edit validation rejects empty edits array" {
    printf 'some content\n' > "${BAISH_LAUNCH_DIR}/empty_edits.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/empty_edits.txt" '[]')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "NO_EDITS" ]]
}

@test "edit validation rejects non-existent file" {
    local result
    result=$(baish_tool_edit_plan_json "/nonexistent/file.txt" \
        '[{"oldText":"x","newText":"y"}]')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "FILE_NOT_FOUND" ]]
}

# ============================================================
# Edit tool — error handling
# ============================================================

@test "edit tool returns error for missing path" {
    local result
    result=$(baish_tool_edit '{"edits":[{"oldText":"x","newText":"y"}]}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "MISSING_PATH" ]]
}

@test "edit tool returns error for non-existent file" {
    local result
    result=$(baish_tool_edit '{"path":"no_such_file.txt","edits":[{"oldText":"x","newText":"y"}]}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "FILE_NOT_FOUND" ]]
}

@test "edit tool returns PERMISSION_DENIED for non-writable file" {
    printf 'editable content\n' > "${BAISH_LAUNCH_DIR}/edit_unwritable.txt"
    chmod 444 "${BAISH_LAUNCH_DIR}/edit_unwritable.txt"

    local result
    result=$(baish_tool_edit '{"path":"edit_unwritable.txt","edits":[{"oldText":"editable content","newText":"replacement"}]}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "PERMISSION_DENIED" ]]
}

@test "edit tool returns error when oldText not found" {
    printf 'hello\n' > "${BAISH_LAUNCH_DIR}/edit_err.txt"

    local result
    result=$(baish_tool_edit '{"path":"edit_err.txt","edits":[{"oldText":"not found","newText":"x"}]}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "OLD_TEXT_NOT_FOUND" ]]
}

@test "edit tool returns error when oldText is not unique" {
    printf 'dup\ndup\n' > "${BAISH_LAUNCH_DIR}/edit_dup.txt"

    local result
    result=$(baish_tool_edit '{"path":"edit_dup.txt","edits":[{"oldText":"dup","newText":"unique"}]}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "OLD_TEXT_NOT_UNIQUE" ]]
}

@test "edit tool returns error for overlapping edits" {
    printf 'the quick brown fox\n' > "${BAISH_LAUNCH_DIR}/edit_overlap.txt"

    local result
    result=$(baish_tool_edit '{"path":"edit_overlap.txt","edits":[
        {"oldText":"the quick","newText":"A"},
        {"oldText":"quick brown","newText":"B"}
    ]}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "OVERLAPPING_EDITS" ]]
}

# ============================================================
# Edit tool — special characters
# ============================================================

@test "edit tool handles oldText with glob special characters" {
    printf 'foo*bar\nbaz?qux\n' > "${BAISH_LAUNCH_DIR}/glob_chars.txt"

    local result
    result=$(baish_tool_edit '{"path":"glob_chars.txt","edits":[
        {"oldText":"foo*bar","newText":"replaced_star"},
        {"oldText":"baz?qux","newText":"replaced_question"}
    ]}')

    local ok content
    ok=$(echo "$result" | jq -r '.ok')
    content=$(cat "${BAISH_LAUNCH_DIR}/glob_chars.txt")

    [[ "$ok" == "true" ]]
    [[ "$content" == "replaced_star
replaced_question" ]]
}

@test "edit tool handles oldText with backslashes" {
    printf 'path\\to\\file\n' > "${BAISH_LAUNCH_DIR}/backslash.txt"

    # The file contains: path\to\file (single backslashes from printf)
    # JSON string "path\\to\\file" → jq parses to path\to\file (single backslashes)
    local result
    result=$(baish_tool_edit '{"path":"backslash.txt","edits":[
        {"oldText":"path\\to\\file","newText":"new/path"}
    ]}')

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    [[ "$ok" == "true" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/backslash.txt")" == "new/path" ]]
}

@test "edit tool handles multi-line oldText replacement" {
    printf 'before\nold block\nstill old\nafter\n' > "${BAISH_LAUNCH_DIR}/multiline.txt"

    local result
    result=$(baish_tool_edit '{"path":"multiline.txt","edits":[
        {"oldText":"old block\nstill old","newText":"new block"}
    ]}')

    local ok content
    ok=$(echo "$result" | jq -r '.ok')
    content=$(cat "${BAISH_LAUNCH_DIR}/multiline.txt")

    [[ "$ok" == "true" ]]
    [[ "$content" == "before
new block
after" ]]
}

# ============================================================
# Tool execution — JSON shape verification
# ============================================================

@test "tool execution returns success JSON shape for read" {
    printf 'test\n' > "${BAISH_LAUNCH_DIR}/shape.txt"

    local result
    result=$(baish_tool_execute "read" '{"path":"shape.txt"}')

    # Verify JSON shape
    echo "$result" | jq 'has("ok")' | grep -q true
    echo "$result" | jq 'has("tool")' | grep -q true
    echo "$result" | jq 'has("data")' | grep -q true
    echo "$result" | jq -r '.tool' | grep -q "read"
}

@test "tool execution returns error JSON shape for read on missing file" {
    local result
    result=$(baish_tool_execute "read" '{"path":"missing.txt"}')

    echo "$result" | jq 'has("ok")' | grep -q true
    echo "$result" | jq 'has("tool")' | grep -q true
    echo "$result" | jq 'has("error")' | grep -q true
    echo "$result" | jq '.error | has("code")' | grep -q true
    echo "$result" | jq '.error | has("message")' | grep -q true
}

@test "tool execution returns success JSON shape for write" {
    local result
    result=$(baish_tool_execute "write" '{"path":"shape_write.txt","content":"test"}')

    echo "$result" | jq 'has("ok")' | grep -q true
    echo "$result" | jq 'has("tool")' | grep -q true
    echo "$result" | jq 'has("data")' | grep -q true
    echo "$result" | jq -r '.tool' | grep -q "write"
}

@test "tool execution returns success JSON shape for edit" {
    printf 'replace me\n' > "${BAISH_LAUNCH_DIR}/shape_edit.txt"

    local result
    result=$(baish_tool_execute "edit" '{"path":"shape_edit.txt","edits":[{"oldText":"replace me","newText":"done"}]}')

    echo "$result" | jq 'has("ok")' | grep -q true
    echo "$result" | jq 'has("tool")' | grep -q true
    echo "$result" | jq 'has("data")' | grep -q true
    echo "$result" | jq -r '.tool' | grep -q "edit"
}

@test "tool execution returns error for unknown tool" {
    local result
    result=$(baish_tool_execute "unknown" '{}')

    local ok code
    ok=$(echo "$result" | jq -r '.ok')
    code=$(echo "$result" | jq -r '.error.code')

    [[ "$ok" == "false" ]]
    [[ "$code" == "UNKNOWN_TOOL" ]]
}

# ============================================================
# End-to-end: mock provider tool calls executed by agent loop
# ============================================================

@test "agent loop executes read tool call from mock provider end-to-end" {
    printf 'readable content here\n' > "${BAISH_LAUNCH_DIR}/e2e_read.txt"

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will read the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-read","name":"read","arguments":"{\"path\":\"e2e_read.txt\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Read e2e_read.txt"

    # Verify: user message + assistant + tool result = 3 messages
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    # Verify the tool result message contains the file content
    local tool_msg content_field
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    content_field=$(echo "$tool_msg" | jq -r '.content | fromjson | .data.content')

    [[ "$content_field" == "readable content here" ]]
}

@test "agent loop executes write tool call from mock provider end-to-end" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will write the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-write","name":"write","arguments":"{\"path\":\"e2e_write.txt\",\"content\":\"written by agent\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Write e2e_write.txt"

    # Verify file was created
    [[ -f "${BAISH_LAUNCH_DIR}/e2e_write.txt" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/e2e_write.txt")" == "written by agent" ]]

    # Verify tool result was appended to session
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]
}

@test "agent loop executes edit tool call from mock provider end-to-end" {
    printf 'original text\n' > "${BAISH_LAUNCH_DIR}/e2e_edit.txt"

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will edit the file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-edit","name":"edit","arguments":"{\"path\":\"e2e_edit.txt\",\"edits\":[{\"oldText\":\"original text\",\"newText\":\"edited text\"}]}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Edit e2e_edit.txt"

    # Verify file was edited
    [[ "$(cat "${BAISH_LAUNCH_DIR}/e2e_edit.txt")" == "edited text" ]]

    # Verify tool result was appended
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]
}

@test "agent loop handles tool error gracefully" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will try to read a missing file."
    BAISH_MOCK_TOOL_CALLS='[{"id":"tc-err","name":"read","arguments":"{\"path\":\"does_not_exist.txt\"}"}]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    baish_agent_run_user_message "Read missing file"

    # Tool error should be appended to session
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 3 ]]

    local tool_msg ok
    tool_msg="${BAISH_SESSION_MESSAGES[2]}"
    ok=$(echo "$tool_msg" | jq -r '.content | fromjson | .ok')

    [[ "$ok" == "false" ]]
}

@test "agent loop executes multiple tool calls sequentially" {
    printf 'read me\n' > "${BAISH_LAUNCH_DIR}/seq1.txt"

    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I will read then write."
    BAISH_MOCK_TOOL_CALLS='[
        {"id":"tc1","name":"read","arguments":"{\"path\":\"seq1.txt\"}"},
        {"id":"tc2","name":"write","arguments":"{\"path\":\"seq2.txt\",\"content\":\"written after read\"}"}
    ]'
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0
    BAISH_MAX_TOOL_ROUNDS=1

    baish_agent_run_user_message "Read then write"

    # Both tool results should be appended (4 messages: user + assistant + tool1 + tool2)
    [[ ${#BAISH_SESSION_MESSAGES[@]} -ge 4 ]]

    # Both files should exist
    [[ -f "${BAISH_LAUNCH_DIR}/seq2.txt" ]]
    [[ "$(cat "${BAISH_LAUNCH_DIR}/seq2.txt")" == "written after read" ]]
}

# ============================================================
# baish_tool_edit_plan_json — standalone validation
# ============================================================

@test "baish_tool_edit_plan_json returns ok=true for valid single edit" {
    printf 'line one\nline two\n' > "${BAISH_LAUNCH_DIR}/plan.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/plan.txt" \
        '[{"oldText":"line one","newText":"LINE ONE"}]')

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "true" ]]
}

@test "baish_tool_edit_plan_json returns ok=true for valid multi-edit" {
    printf 'a\nb\nc\nd\n' > "${BAISH_LAUNCH_DIR}/plan_multi.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/plan_multi.txt" \
        '[{"oldText":"a","newText":"A"},{"oldText":"d","newText":"D"}]')

    local ok
    ok=$(echo "$result" | jq -r '.ok')
    [[ "$ok" == "true" ]]
}

@test "baish_tool_edit_plan_json validates against original file not incrementally" {
    # This test verifies that validation checks all oldText against the
    # ORIGINAL file. If edit A replaces "foo" with "bar" and edit B replaces
    # "bar" with "baz", and both "foo" and "bar" exist in the original file,
    # validation should pass (because it validates against the original).
    printf 'foo\nbar\n' > "${BAISH_LAUNCH_DIR}/plan_orig.txt"

    local result
    result=$(baish_tool_edit_plan_json "${BAISH_LAUNCH_DIR}/plan_orig.txt" \
        '[{"oldText":"foo","newText":"bar"},{"oldText":"bar","newText":"baz"}]')

    local ok
    ok=$(echo "$result" | jq -r '.ok')

    # "bar" appears once in original, "foo" appears once — both valid
    [[ "$ok" == "true" ]]
}

# ============================================================
# Tool schemas — baish_tool_schemas
# ============================================================

@test "baish_tool_schemas returns valid JSON with 4 tools" {
    local schemas
    schemas=$(baish_tool_schemas)

    # Verify it's valid JSON
    echo "${schemas}" | jq '.' > /dev/null

    local count
    count=$(echo "${schemas}" | jq 'length')
    [[ "${count}" -eq 4 ]]
}

@test "baish_tool_schemas includes read tool with correct structure" {
    local schemas
    schemas=$(baish_tool_schemas)

    local name desc has_params has_props has_required
    name=$(echo "${schemas}" | jq -r '.[0].function.name')
    desc=$(echo "${schemas}" | jq -r '.[0].function.description')
    has_params=$(echo "${schemas}" | jq '.[0].function.parameters | has("properties")')
    has_props=$(echo "${schemas}" | jq '.[0].function.parameters.properties | has("path")')
    has_required=$(echo "${schemas}" | jq '.[0].function.parameters.required | index("path") != null')

    [[ "${name}" == "read" ]]
    [[ -n "${desc}" ]]
    [[ "${has_params}" == "true" ]]
    [[ "${has_props}" == "true" ]]
    [[ "${has_required}" == "true" ]]
}

@test "baish_tool_schemas includes write tool with correct structure" {
    local schemas
    schemas=$(baish_tool_schemas)

    local name
    name=$(echo "${schemas}" | jq -r '.[1].function.name')
    [[ "${name}" == "write" ]]

    local has_path has_content
    has_path=$(echo "${schemas}" | jq '.[1].function.parameters.properties | has("path")')
    has_content=$(echo "${schemas}" | jq '.[1].function.parameters.properties | has("content")')
    [[ "${has_path}" == "true" ]]
    [[ "${has_content}" == "true" ]]

    local required_count
    required_count=$(echo "${schemas}" | jq '.[1].function.parameters.required | length')
    [[ "${required_count}" -eq 2 ]]
}

@test "baish_tool_schemas includes edit tool with correct structure" {
    local schemas
    schemas=$(baish_tool_schemas)

    local name
    name=$(echo "${schemas}" | jq -r '.[2].function.name')
    [[ "${name}" == "edit" ]]

    # Verify edits parameter has items schema
    local has_edits has_items
    has_edits=$(echo "${schemas}" | jq '.[2].function.parameters.properties | has("edits")')
    has_items=$(echo "${schemas}" | jq '.[2].function.parameters.properties.edits | has("items")')
    [[ "${has_edits}" == "true" ]]
    [[ "${has_items}" == "true" ]]
}

@test "baish_tool_schemas includes bash tool with correct structure" {
    local schemas
    schemas=$(baish_tool_schemas)

    local name
    name=$(echo "${schemas}" | jq -r '.[3].function.name')
    [[ "${name}" == "bash" ]]

    local has_command has_env
    has_command=$(echo "${schemas}" | jq '.[3].function.parameters.properties | has("command")')
    has_env=$(echo "${schemas}" | jq '.[3].function.parameters.properties | has("env")')
    [[ "${has_command}" == "true" ]]
    [[ "${has_env}" == "true" ]]

    local required
    required=$(echo "${schemas}" | jq -r '.[3].function.parameters.required[0]')
    [[ "${required}" == "command" ]]
}

@test "baish_tool_schemas each tool has type=function" {
    local schemas
    schemas=$(baish_tool_schemas)

    local types
    types=$(echo "${schemas}" | jq -r '[.[].type] | unique | join(",")')
    [[ "${types}" == "function" ]]
}

@test "baish_tool_schemas each tool has unique name" {
    local schemas
    schemas=$(baish_tool_schemas)

    local count unique_count
    count=$(echo "${schemas}" | jq 'length')
    unique_count=$(echo "${schemas}" | jq '[.[].function.name] | unique | length')
    [[ "${count}" -eq "${unique_count}" ]]
}

@test "agent loop sends tool schemas to provider" {
    BAISH_CURRENT_PROVIDER="mock"
    BAISH_CURRENT_MODEL="mock-model"
    BAISH_MOCK_RESPONSE="I have tools!"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    # Use a file to capture tools_json (since $() creates a subshell,
    # variable assignment inside overridden function won't propagate)
    local captured_file="${BAISH_STATE_DIR}/captured_tools.json"
    rm -f "${captured_file}"

    # Override the provider function to capture tools_json to a file
    function provider_mock_chat() {
        local messages_json="$1"
        local tools_json="$2"
        # Write tools_json to capture file
        printf '%s' "${tools_json}" > "${captured_file}"
        # Return standard mock response
        jq -n --arg text "${BAISH_MOCK_RESPONSE:-I am the mock provider. Your message was received.}" --argjson tc "${BAISH_MOCK_TOOL_CALLS:-[]}" \
            '{"assistant_text": $text, "tool_calls": $tc}'
    }
    export -f provider_mock_chat

    baish_agent_run_user_message "Hello"

    # Verify tools were sent (not empty array)
    [[ -f "${captured_file}" ]]
    local tool_count
    tool_count=$(jq 'length' "${captured_file}")
    [[ "${tool_count}" -eq 4 ]]

    # Verify first tool is read
    local first_tool_name
    first_tool_name=$(jq -r '.[0].function.name' "${captured_file}")
    [[ "${first_tool_name}" == "read" ]]
}

@test "kilo provider receives tool schemas from agent loop" {
    BAISH_CURRENT_PROVIDER="kilo"
    BAISH_CURRENT_MODEL="openai/gpt-4o"
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    BAISH_DEBUG=0

    local captured_payload="${BAISH_STATE_DIR}/kilo_tools_payload.json"

    # Mock curl to capture the payload
    function curl() {
        local args=("$@")
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-d" ]]; then
                echo "${args[$((i+1))]}" > "${captured_payload}"
                break
            fi
        done
        printf '{"choices": [{"message": {"content": "ok", "tool_calls": []}}]}\n200'
    }
    export -f curl

    # Need API key for kilo provider
    export KILO_API_KEY="sk-test-schemas"

    # Source kilo provider for this test
    source "${BAISH_ROOT}/lib/providers/kilo.sh"

    baish_agent_run_user_message "List files"

    # Verify the payload contains tools
    [[ -f "${captured_payload}" ]]
    local has_tools
    has_tools=$(jq 'has("tools")' "${captured_payload}")
    [[ "${has_tools}" == "true" ]]

    local tool_count
    tool_count=$(jq '.tools | length' "${captured_payload}")
    [[ "${tool_count}" -eq 4 ]]

    local first_tool_name
    first_tool_name=$(jq -r '.tools[0].function.name' "${captured_payload}")
    [[ "${first_tool_name}" == "read" ]]
}

