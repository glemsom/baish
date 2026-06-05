#!/usr/bin/env bats
# BAISH — Unit tests: output announcement functions
# Tests the format contract of each announcement function in isolation,
# and the description extraction + truncation logic.

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Source output module in isolation (no mock provider or agent loop needed)
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
}

# ── Description extraction ──────────────────────────────────────────────

@test "_baish_output_tool_description extracts path for read tool" {
    local desc
    desc=$(_baish_output_tool_description '{"path": "/home/user/file.txt"}')
    [[ "$desc" == "/home/user/file.txt" ]]
}

@test "_baish_output_tool_description extracts path for write tool" {
    local desc
    desc=$(_baish_output_tool_description '{"path": "output.md"}')
    [[ "$desc" == "output.md" ]]
}

@test "_baish_output_tool_description extracts path for edit tool" {
    local desc
    desc=$(_baish_output_tool_description '{"path": "config.yaml"}')
    [[ "$desc" == "config.yaml" ]]
}

@test "_baish_output_tool_description extracts command for bash tool" {
    local desc
    desc=$(_baish_output_tool_description '{"command": "echo hello world"}')
    [[ "$desc" == "echo hello world" ]]
}

@test "_baish_output_tool_description returns ? when no path or command" {
    local desc
    desc=$(_baish_output_tool_description '{}')
    [[ "$desc" == "?" ]]
}

@test "_baish_output_tool_description prefers path over command when both present" {
    local desc
    desc=$(_baish_output_tool_description '{"path": "file.txt", "command": "rm -rf /"}')
    [[ "$desc" == "file.txt" ]]
}

# ── Truncation ──────────────────────────────────────────────────────────

@test "_baish_output_tool_description truncates commands over 100 chars with …" {
    # Build a 150-character command
    local long_cmd
    long_cmd=$(printf 'x%.0s' $(seq 1 150))

    local args_json
    args_json=$(jq -n --arg cmd "$long_cmd" '{"command": $cmd}')

    local desc
    desc=$(_baish_output_tool_description "$args_json")

    # Should be exactly 100 characters: 99 prefix chars + "…"
    [[ "${#desc}" -eq 100 ]]

    # Should start with the first 99 chars of the command
    [[ "$desc" == "${long_cmd:0:99}…" ]]
}

@test "_baish_output_tool_description does not truncate exactly 100-char command" {
    local cmd_100
    cmd_100=$(printf 'y%.0s' $(seq 1 100))

    local args_json
    args_json=$(jq -n --arg cmd "$cmd_100" '{"command": $cmd}')

    local desc
    desc=$(_baish_output_tool_description "$args_json")

    # Should remain exactly 100 chars, no ellipsis
    [[ "${#desc}" -eq 100 ]]
    [[ "$desc" == "$cmd_100" ]]
}

@test "_baish_output_tool_description truncates long paths just like commands" {
    local long_path
    long_path=$(printf 'd/%.0s' $(seq 1 75))  # 150 chars

    local args_json
    args_json=$(jq -n --arg path "$long_path" '{"path": $path}')

    local desc
    desc=$(_baish_output_tool_description "$args_json")

    [[ "${#desc}" -eq 100 ]]
    [[ "$desc" == "${long_path:0:99}…" ]]
}

# ── Announce format: baish_output_tool_announce ──────────────────────────

@test "baish_output_tool_announce starts with \\r, contains 🔄, icon, and description" {
    local output
    output=$(baish_output_tool_announce "read" "/path/to/file.txt")

    # Starts with carriage return
    [[ "$output" == $'\r'* ]]

    # Contains the 🔄 (in-progress) emoji
    [[ "$output" == *"🔄"* ]]

    # Contains the correct tool icon (📖 for read)
    [[ "$output" == *"📖"* ]]

    # Contains the description
    [[ "$output" == *"/path/to/file.txt"* ]]
}

@test "baish_output_tool_announce has no trailing newline" {
    # Write output to a temp file so we can inspect the exact bytes
    local tmpfile
    tmpfile=$(mktemp)
    baish_output_tool_announce "edit" "config.yaml" > "$tmpfile"
    local last_char
    last_char=$(tail -c 1 "$tmpfile" | od -An -tx1 | tr -d ' ')
    rm -f "$tmpfile"

    # Should NOT end with a newline (0x0a)
    [[ "$last_char" != "0a" ]]
}

@test "baish_output_tool_announce uses correct icon for write" {
    local output
    output=$(baish_output_tool_announce "write" "notes.md")

    [[ "$output" == *"📝"* ]]
}

@test "baish_output_tool_announce uses correct icon for edit" {
    local output
    output=$(baish_output_tool_announce "edit" "config.yaml")

    [[ "$output" == *"✏️"* ]]
}

@test "baish_output_tool_announce uses correct icon for bash" {
    local output
    output=$(baish_output_tool_announce "bash" "ls -la")

    [[ "$output" == *"⚙️"* ]]
}

@test "baish_output_tool_announce uses default icon for unknown tool" {
    local output
    output=$(baish_output_tool_announce "unknown_tool" "some desc")

    [[ "$output" == *"🔧"* ]]
    [[ "$output" == *"🔄"* ]]
    [[ "$output" == *"some desc"* ]]
}

# ── Announce format: baish_output_tool_announce_ok ──────────────────────

@test "baish_output_tool_announce_ok starts with \\r\\033[K, contains ✅, icon, and description" {
    local output
    output=$(baish_output_tool_announce_ok "read" "/path/to/file.txt")

    # Starts with \r\033[K (carriage return + clear-to-end-of-line)
    [[ "$output" == $'\r\033[K'* ]]

    # Contains the ✅ (success) emoji
    [[ "$output" == *"✅"* ]]

    # Contains the correct tool icon
    [[ "$output" == *"📖"* ]]

    # Contains the description
    [[ "$output" == *"/path/to/file.txt"* ]]
}

@test "baish_output_tool_announce_ok has trailing newline" {
    # Command substitution strips trailing newlines; use a file + od to check
    local tmpfile
    tmpfile=$(mktemp)
    baish_output_tool_announce_ok "write" "notes.md" > "$tmpfile"
    # The last character in the file should be a newline
    local last_char
    last_char=$(tail -c 1 "$tmpfile" | od -An -tx1 | tr -d ' ')
    rm -f "$tmpfile"
    [[ "$last_char" == "0a" ]]
}

@test "baish_output_tool_announce_ok uses correct icon for bash" {
    local output
    output=$(baish_output_tool_announce_ok "bash" "ls -la")

    [[ "$output" == *"⚙️"* ]]
    [[ "$output" == *"✅"* ]]
    [[ "$output" == *"ls -la"* ]]
}

# ── Announce format: baish_output_tool_announce_error ───────────────────

@test "baish_output_tool_announce_error starts with \\r\\033[K, contains ❌, description, and error message" {
    local output
    output=$(baish_output_tool_announce_error "edit" "config.yaml" "oldText not found in file")

    # Starts with \r\033[K
    [[ "$output" == $'\r\033[K'* ]]

    # Contains the ❌ (error) emoji
    [[ "$output" == *"❌"* ]]

    # Contains the correct tool icon
    [[ "$output" == *"✏️"* ]]

    # Contains the description
    [[ "$output" == *"config.yaml"* ]]

    # Contains the error message
    [[ "$output" == *"oldText not found in file"* ]]

    # Description and error message should be separated by em-dash
    [[ "$output" == *" — "* ]]
}

@test "baish_output_tool_announce_error has trailing newline" {
    local tmpfile
    tmpfile=$(mktemp)
    baish_output_tool_announce_error "read" "missing.txt" "File not found" > "$tmpfile"
    local last_char
    last_char=$(tail -c 1 "$tmpfile" | od -An -tx1 | tr -d ' ')
    rm -f "$tmpfile"
    [[ "$last_char" == "0a" ]]
}

@test "baish_output_tool_announce_error uses correct icon for read" {
    local output
    output=$(baish_output_tool_announce_error "read" "nonexistent.txt" "FILE_NOT_FOUND")

    [[ "$output" == *"📖"* ]]
    [[ "$output" == *"❌"* ]]
    [[ "$output" == *"nonexistent.txt"* ]]
    [[ "$output" == *"FILE_NOT_FOUND"* ]]
}

@test "baish_output_tool_announce_error uses correct icon for bash" {
    local output
    output=$(baish_output_tool_announce_error "bash" "rm -rf /" "Permission denied")

    [[ "$output" == *"⚙️"* ]]
    [[ "$output" == *"❌"* ]]
    [[ "$output" == *"rm -rf /"* ]]
    [[ "$output" == *"Permission denied"* ]]
}
