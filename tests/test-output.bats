#!/usr/bin/env bats
# BAISH — Unit tests: output announcement functions
# Tests the format contract of each announcement function in isolation,
# and the description extraction + truncation logic.

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Ensure UTF-8 locale for correct multi-byte character counting (e.g., "…")
    export LC_ALL=C.UTF-8

    # Source output module in isolation (no mock provider or agent loop needed)
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
    source "${BAISH_ROOT}/lib/agent/agents-md.sh"

    # Reset AGENTS.md loaded files so context summary tests start clean
    BAISH_AGENTS_MD_LOADED_FILES=()
    BAISH_SESSION_SKILL_NAMES=()
}

# ── Banner ────────────────────────────────────────────────────────────

@test "baish_output_banner prints BAISH title and help text" {
    local output
    output=$(baish_output_banner)

    # Contains the BAISH title
    [[ "$output" == *"BAISH — Bash AI Shell"* ]]

    # Contains the help hint
    [[ "$output" == *"Type a message or /help for commands"* ]]

    # Contains box drawing characters (top border)
    [[ "$output" == *"╔══════════════════════════════════════════╗"* ]]

    # Contains box drawing characters (bottom border)
    [[ "$output" == *"╚══════════════════════════════════════════╝"* ]]

    # Output is non-empty and starts with a newline
    [[ -n "$output" ]]
    [[ "$output" == $'\n'* ]]
}

# ── Prompt ────────────────────────────────────────────────────────────

@test "baish_output_prompt includes provider and model in output" {
    local output
    output=$(baish_output_prompt "test-provider" "test-model")

    # Contains provider and model in expected format
    [[ "$output" == *"test-provider"* ]]
    [[ "$output" == *"test-model"* ]]
    [[ "$output" == *"["*"test-provider"*"/"*"test-model"*"]"* ]]

    # Ends with '> ' prompt suffix
    [[ "$output" == *"> " ]]

    # Contains ANSI color codes (green reset before prompt suffix)
    [[ "$output" == *$'\033[0m'* ]]
}

@test "baish_output_prompt handles provider and model with special chars" {
    local output
    output=$(baish_output_prompt "gpt-4o" "claude-3.5-sonnet")

    [[ "$output" == *"gpt-4o"* ]]
    [[ "$output" == *"claude-3.5-sonnet"* ]]
    [[ "$output" == *"> " ]]
}

# ── Readline prompt ────────────────────────────────────────────────────

@test "baish_output_readline_prompt wraps ANSI escapes in \\001/\\002 markers" {
    local output
    output=$(baish_output_readline_prompt "provider" "model")

    # Contains \001 (start of non-printing chars for readline)
    [[ "$output" == *$'\001'* ]]

    # Contains \002 (end of non-printing chars for readline)
    [[ "$output" == *$'\002'* ]]

    # Contains provider/model in brackets
    [[ "$output" == *"[provider/model]"* ]]

    # Ends with ' > ' suffix
    [[ "$output" == *" > " ]]
}

@test "baish_output_readline_prompt properly escapes green color for readline" {
    local output
    output=$(baish_output_readline_prompt "my-provider" "my-model")

    # The ANSI green code should be wrapped in \001/\002
    # Pattern: \001\033[32m\002[my-provider/my-model]\001\033[0m\002 >
    [[ "$output" == *$'\001\033[32m\002'* ]]
    [[ "$output" == *$'\001\033[0m\002'* ]]
}

# ── Tool result ───────────────────────────────────────────────────────

@test "baish_output_tool_result includes tool icon and summary" {
    local output
    output=$(baish_output_tool_result "read" "read file.txt (42 lines)")

    # Contains the correct tool icon (📖 for read)
    [[ "$output" == *"📖"* ]]

    # Contains the summary text
    [[ "$output" == *"read file.txt (42 lines)"* ]]

    # Starts with dim color code
    [[ "$output" == $'\033[2m'* ]]

    # Ends with reset + newline
    [[ "$output" == *$'\033[0m' ]]
}

@test "baish_output_tool_result uses correct icon per tool" {
    local read_output
    read_output=$(baish_output_tool_result "read" "summary")
    [[ "$read_output" == *"📖"* ]]

    local write_output
    write_output=$(baish_output_tool_result "write" "summary")
    [[ "$write_output" == *"📝"* ]]

    local edit_output
    edit_output=$(baish_output_tool_result "edit" "summary")
    [[ "$edit_output" == *"✏️"* ]]

    local bash_output
    bash_output=$(baish_output_tool_result "bash" "summary")
    [[ "$bash_output" == *"⚙️"* ]]

    local unknown_output
    unknown_output=$(baish_output_tool_result "some_other" "summary")
    [[ "$unknown_output" == *"🔧"* ]]
}

@test "baish_output_tool_result has trailing newline" {
    local tmpfile
    tmpfile=$(mktemp)
    baish_output_tool_result "read" "summary" > "$tmpfile"
    local last_char
    last_char=$(tail -c 1 "$tmpfile" | od -An -tx1 | tr -d ' ')
    rm -f "$tmpfile"
    [[ "$last_char" == "0a" ]]
}

# ── Tool error ─────────────────────────────────────────────────────────

@test "baish_output_tool_error includes ❌ icon, tool name, and error message" {
    local output
    output=$(baish_output_tool_error "read" "FILE_NOT_FOUND")

    # Contains the ❌ (error) icon
    [[ "$output" == *"❌"* ]]

    # Contains the tool name
    [[ "$output" == *"read"* ]]

    # Contains the error message
    [[ "$output" == *"FILE_NOT_FOUND"* ]]

    # Starts with dim color code
    [[ "$output" == $'\033[2m'* ]]

    # Ends with reset + newline
    [[ "$output" == *$'\033[0m' ]]

    # Format is "  ❌ tool_name: error_msg"
    [[ "$output" == *"❌ read: FILE_NOT_FOUND"* ]]
}

@test "baish_output_tool_error has trailing newline" {
    local tmpfile
    tmpfile=$(mktemp)
    baish_output_tool_error "write" "PERMISSION_DENIED" > "$tmpfile"
    local last_char
    last_char=$(tail -c 1 "$tmpfile" | od -An -tx1 | tr -d ' ')
    rm -f "$tmpfile"
    [[ "$last_char" == "0a" ]]
}

@test "baish_output_tool_error handles errors with spaces and special chars" {
    local output
    output=$(baish_output_tool_error "bash" "Command 'foo' not found, did you mean:")

    [[ "$output" == *"❌"* ]]
    [[ "$output" == *"bash"* ]]
    [[ "$output" == *"Command 'foo' not found, did you mean:"* ]]
}

# ── Thinking spinner ───────────────────────────────────────────────────

@test "baish_output_thinking renders spinner characters while process is alive" {
    # Start a background sleep process
    sleep 0.3 &
    local pid=$!

    # Run thinking with a timeout to capture output
    # We capture the first ~200ms of spinner output
    local tmpfile
    tmpfile=$(mktemp)
    baish_output_thinking "$pid" > "$tmpfile" 2>/dev/null &
    local thinking_pid=$!

    # Wait for some spinner frames to render
    sleep 0.25

    # Kill the background process and the thinking function
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    wait "$thinking_pid" 2>/dev/null || true

    local output
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    # Output contains the "thinking..." label
    [[ "$output" == *"thinking..."* ]]

    # Output contains at least one spinner character
    [[ "$output" == *"⠋"* || "$output" == *"⠙"* || "$output" == *"⠹"* ]]
}

@test "baish_output_thinking shows cyan color code" {
    # Quick test that ANSI color codes are emitted
    sleep 0.1 &
    local pid=$!

    local tmpfile
    tmpfile=$(mktemp)
    baish_output_thinking "$pid" > "$tmpfile" 2>/dev/null &
    local thinking_pid=$!

    sleep 0.15
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    wait "$thinking_pid" 2>/dev/null || true

    local output
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    # Contains cyan color escape
    [[ "$output" == *$'\033[36m'* ]]
    [[ "$output" == *$'\033[0m'* ]]
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

# ── Context summary (startup) ───────────────────────────────────────────

@test "baish_output_context_summary shows 'no additional context' when nothing loaded" {
    BAISH_AGENTS_MD_LOADED_FILES=()
    BAISH_SESSION_SKILL_NAMES=()

    local output
    output=$(baish_output_context_summary)

    [[ "$output" == *"No additional context files loaded"* ]]
}

@test "baish_output_context_summary shows loaded AGENTS.md files" {
    local fake_home="/tmp/fake-home-$$"
    mkdir -p "${fake_home}/.baish"
    # Temporarily override HOME so path display works
    local saved_home="${HOME}"
    HOME="${fake_home}"
    BAISH_AGENTS_MD_LOADED_FILES=("${fake_home}/.baish/AGENTS.md")
    BAISH_SESSION_SKILL_NAMES=()

    local output
    output=$(baish_output_context_summary)

    HOME="${saved_home}"
    rm -rf "${fake_home}"

    # Should mention AGENTS.md (singular for one file)
    [[ "$output" == *"AGENTS.md"* ]]
    # The path should be shortened with ~/ prefix
    [[ "$output" == *"~/.baish/AGENTS.md"* ]]
}

@test "baish_output_context_summary shows loaded skills" {
    BAISH_AGENTS_MD_LOADED_FILES=()
    BAISH_SESSION_SKILL_NAMES=("tdd" "diagnose")

    local output
    output=$(baish_output_context_summary)

    # Should mention skills (plural for 2+)
    [[ "$output" == *"skills"* ]]
    [[ "$output" == *"tdd"* ]]
    [[ "$output" == *"diagnose"* ]]
    # Should not mention singular 'skill'
    [[ "$output" != *"skill:"* ]]
}

@test "baish_output_context_summary shows both AGENTS.md and skills when both loaded" {
    BAISH_AGENTS_MD_LOADED_FILES=("/tmp/test-global/AGENTS.md")
    BAISH_SESSION_SKILL_NAMES=("tdd")

    local output
    output=$(baish_output_context_summary)

    # Should mention both
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" == *"tdd"* ]]
}

@test "baish_output_context_summary uses singular 'skill' for exactly one skill" {
    BAISH_AGENTS_MD_LOADED_FILES=()
    BAISH_SESSION_SKILL_NAMES=("tdd")

    local output
    output=$(baish_output_context_summary)

    [[ "$output" == *"skill:"* ]]
}
