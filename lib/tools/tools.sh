#!/usr/bin/env bash
# BAISH — File tools: read, write, edit
# Bash execution tool
# Each tool accepts standardized JSON arguments and returns structured JSON results.

# ============================================================
# Tool result helpers
# ============================================================

# Build a success result JSON object.
# Args: tool_name, data_json
baish_tool_success_json() {
    local tool_name="$1"
    local data_json="$2"
    jq -n --arg tool "${tool_name}" --argjson data "${data_json}" \
        '{"ok": true, "tool": $tool, "data": $data}'
}

# Build an error result JSON object.
# Args: tool_name, error_code, error_message
baish_tool_error_json() {
    local tool_name="$1"
    local code="$2"
    local message="$3"
    jq -n --arg tool "${tool_name}" --arg code "${code}" --arg message "${message}" \
        '{"ok": false, "tool": $tool, "error": {"code": $code, "message": $message}}'
}

# Main tool dispatcher — routes a tool name + arguments to the correct
# tool implementation. Returns standardized success/error JSON.
baish_tool_execute() {
    local tool_name="$1"
    local args_json="$2"

    case "${tool_name}" in
        read)
            baish_tool_read "${args_json}"
            ;;
        write)
            baish_tool_write "${args_json}"
            ;;
        edit)
            baish_tool_edit "${args_json}"
            ;;
        bash)
            baish_tool_bash "${args_json}"
            ;;
        *)
            baish_tool_error_json "${tool_name}" "UNKNOWN_TOOL" "Unknown tool: ${tool_name}"
            ;;
    esac
}

# ============================================================
# Path resolution
# ============================================================

# Resolve a path relative to the launch directory.
# Absolute paths are returned as-is.
baish_resolve_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s' "$path"
    else
        printf '%s' "${BAISH_LAUNCH_DIR:-$PWD}/${path}"
    fi
}

# ============================================================
# Glob-escape helper for bash pattern matching
# ============================================================

# Escape special glob characters so a string can be used as a
# literal pattern in ${var%%pattern*} style operations.
_glob_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//[/\\[}"
    s="${s//]/\\]}"
    printf '%s' "$s"
}

# Count how many times a literal pattern appears in a string.
# Uses glob-escaped pattern matching for correctness.
_count_occurrences() {
    local content="$1" pattern="$2"
    local count=0 remaining="$content"
    local escaped
    escaped=$(_glob_escape "$pattern")
    while [[ "$remaining" == *${escaped}* ]]; do
        count=$((count + 1))
        remaining="${remaining#*${escaped}}"
    done
    echo "$count"
}

# Find the 0-indexed position of the first occurrence of a literal
# pattern in a string. Returns -1 if not found.
_find_position() {
    local content="$1" pattern="$2"
    local escaped
    escaped=$(_glob_escape "$pattern")
    if [[ "$content" != *${escaped}* ]]; then
        echo "-1"
        return
    fi
    local before="${content%%${escaped}*}"
    echo "${#before}"
}

# ============================================================
# Read tool
# ============================================================
# Arguments (JSON):
#   path   - file path (required, relative to launch dir)
#   offset - 1-indexed line to start from (default: 1)
#   limit  - max lines to read (default: 0 = no limit)
baish_tool_read() {
    local args_json="$1"
    local path offset limit

    path=$(echo "$args_json" | jq -r '.path // empty')
    offset=$(echo "$args_json" | jq -r '.offset // 1')
    limit=$(echo "$args_json" | jq -r '.limit // 0')

    if [[ -z "$path" ]]; then
        baish_tool_error_json "read" "MISSING_PATH" "The 'path' argument is required"
        return 0
    fi

    path=$(baish_resolve_path "$path")

    if [[ -d "$path" ]]; then
        baish_tool_error_json "read" "IS_DIRECTORY" "Path is a directory: $path"
        return 0
    fi

    if [[ ! -f "$path" ]]; then
        baish_tool_error_json "read" "FILE_NOT_FOUND" "File not found: $path"
        return 0
    fi

    if [[ ! -r "$path" ]]; then
        baish_tool_error_json "read" "PERMISSION_DENIED" "Cannot read file: $path"
        return 0
    fi

    local content
    if [[ "$limit" -eq 0 ]]; then
        content=$(awk -v start="$offset" 'NR >= start' "$path")
    else
        local end_line=$((offset + limit - 1))
        content=$(awk -v start="$offset" -v end="$end_line" 'NR >= start && NR <= end' "$path")
    fi

    local line_count
    if [[ -z "$content" ]]; then
        line_count=0
    else
        line_count=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
    fi

    baish_tool_success_json "read" "$(jq -n \
        --arg path "$path" \
        --arg content "$content" \
        --argjson line_count "$line_count" \
        '{"path": $path, "content": $content, "line_count": $line_count}')"
}

# ============================================================
# Write tool
# ============================================================
# Arguments (JSON):
#   path    - file path (required, relative to launch dir)
#   content - file content to write (required)
#
# Atomic write: creates a temp file in the target directory,
# preserves existing file permissions, then renames.
baish_tool_write() {
    local args_json="$1"
    local path

    path=$(echo "$args_json" | jq -r '.path // empty')

    if [[ -z "$path" ]]; then
        baish_tool_error_json "write" "MISSING_PATH" "The 'path' argument is required"
        return 0
    fi

    path=$(baish_resolve_path "$path")

    if [[ -d "$path" ]]; then
        baish_tool_error_json "write" "IS_DIRECTORY" "Path is a directory: $path"
        return 0
    fi

    # Create parent directories
    mkdir -p "$(dirname "$path")"

    # Atomic write: temp file in /tmp (cleaned up on rename)
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/baish_write.XXXXXX")

    # Write content directly from jq to avoid command-substitution newline stripping
    jq -j '.content // ""' <<< "$args_json" > "$tmpfile"

    # Preserve existing file permissions if file already exists
    if [[ -f "$path" ]]; then
        local mode
        mode=$(stat -c '%a' "$path")
        chmod "$mode" "$tmpfile"
    fi

    # Atomic rename
    mv -- "$tmpfile" "$path"

    local bytes
    bytes=$(wc -c < "$path" | tr -d ' ')

    baish_tool_success_json "write" "$(jq -n \
        --arg path "$path" \
        --argjson bytes "$bytes" \
        '{"path": $path, "bytes_written": $bytes}')"
}

# ============================================================
# Edit validation (baish_tool_edit_plan_json)
# ============================================================
# Validates an edit plan against the ORIGINAL file before any edits
# are applied. Checks:
#   - oldText appears exactly once per edit
#   - no overlapping edit ranges
#
# Arguments:
#   $1 - file path
#   $2 - edits JSON array
#
# Returns JSON: {"ok": true} or {"ok": false, "error": {"code": "...", "message": "..."}}
baish_tool_edit_plan_json() {
    local file_path="$1"
    local edits_json="$2"

    if [[ ! -f "$file_path" ]]; then
        jq -n --arg path "$file_path" \
            '{"ok": false, "error": {"code": "FILE_NOT_FOUND", "message": ("File not found: " + $path)}}'
        return 0
    fi

    local edit_count
    edit_count=$(echo "$edits_json" | jq 'length')

    if [[ "$edit_count" -eq 0 ]]; then
        jq -n '{"ok": false, "error": {"code": "NO_EDITS", "message": "No edits provided"}}'
        return 0
    fi

    # Read the original file content once
    local content
    content=$(cat "$file_path")

    # Step 1: Validate each oldText appears exactly once; record positions
    local -a positions=()
    local -a lengths=()
    local i
    for ((i = 0; i < edit_count; i++)); do
        local old_text
        old_text=$(echo "$edits_json" | jq -r ".[$i].oldText")

        local count
        count=$(_count_occurrences "$content" "$old_text")

        if [[ "$count" -eq 0 ]]; then
            jq -n --arg idx "$i" --arg old "$old_text" \
                '{"ok": false, "error": {"code": "OLD_TEXT_NOT_FOUND", "message": ("Edit #" + $idx + ": oldText not found in file: " + ($old | if length > 80 then .[0:80] + "…" else . end))}}'
            return 0
        fi

        if [[ "$count" -gt 1 ]]; then
            jq -n --arg idx "$i" --arg count "$count" --arg old "$old_text" \
                '{"ok": false, "error": {"code": "OLD_TEXT_NOT_UNIQUE", "message": ("Edit #" + $idx + ": oldText appears " + $count + " times in the file (must appear exactly once). Snippet: " + ($old | if length > 80 then .[0:80] + "…" else . end))}}'
            return 0
        fi

        # Record position
        local pos
        pos=$(_find_position "$content" "$old_text")
        positions+=("$pos")
        lengths+=("${#old_text}")
    done

    # Step 2: Check for overlapping edit ranges
    local j
    for ((i = 0; i < edit_count; i++)); do
        for ((j = i + 1; j < edit_count; j++)); do
            local start_i=${positions[$i]}
            local end_i=$((start_i + lengths[$i]))
            local start_j=${positions[$j]}
            local end_j=$((start_j + lengths[$j]))

            if (( start_i < end_j && start_j < end_i )); then
                jq -n --arg msg "Edit #${i} (position ${start_i}–${end_i}) overlaps with Edit #${j} (position ${start_j}–${end_j})" \
                    '{"ok": false, "error": {"code": "OVERLAPPING_EDITS", "message": $msg}}'
                return 0
            fi
        done
    done

    jq -n '{"ok": true}'
}

# ============================================================
# Edit tool
# ============================================================
# Arguments (JSON):
#   path  - file path (required, relative to launch dir)
#   edits - array of {oldText, newText} (required)
#
# Validates all edits against the original file, then applies
# them atomically (all or none).
baish_tool_edit() {
    local args_json="$1"
    local path edits_json

    path=$(echo "$args_json" | jq -r '.path // empty')
    edits_json=$(echo "$args_json" | jq -c '.edits // []')

    if [[ -z "$path" ]]; then
        baish_tool_error_json "edit" "MISSING_PATH" "The 'path' argument is required"
        return 0
    fi

    path=$(baish_resolve_path "$path")

    if [[ ! -f "$path" ]]; then
        baish_tool_error_json "edit" "FILE_NOT_FOUND" "File not found: $path"
        return 0
    fi

    if [[ ! -w "$path" ]]; then
        baish_tool_error_json "edit" "PERMISSION_DENIED" "Cannot write to file: $path"
        return 0
    fi

    local edit_count
    edit_count=$(echo "$edits_json" | jq 'length')

    if [[ "$edit_count" -eq 0 ]]; then
        baish_tool_error_json "edit" "NO_EDITS" "No edits provided"
        return 0
    fi

    # Validate edits against original file
    local validation
    validation=$(baish_tool_edit_plan_json "$path" "$edits_json")
    local validation_ok
    validation_ok=$(echo "$validation" | jq -r '.ok')

    if [[ "$validation_ok" != "true" ]]; then
        local err_code err_msg
        err_code=$(echo "$validation" | jq -r '.error.code')
        err_msg=$(echo "$validation" | jq -r '.error.message')
        baish_tool_error_json "edit" "$err_code" "$err_msg"
        return 0
    fi

    # Read original content
    local content
    content=$(cat "$path")

    # Collect edit metadata (position, length, replacement)
    local -a starts=() ends=() new_texts=()
    local i
    for ((i = 0; i < edit_count; i++)); do
        local old_text new_text
        old_text=$(echo "$edits_json" | jq -r ".[$i].oldText")
        new_text=$(echo "$edits_json" | jq -r ".[$i].newText")

        local pos
        pos=$(_find_position "$content" "$old_text")

        starts+=("$pos")
        ends+=("$((pos + ${#old_text}))")
        new_texts+=("$new_text")
    done

    # Sort edit indices by position ascending so we can build the result
    # by concatenating segments in order from start to end of file.
    local -a sorted_indices=()
    for ((i = 0; i < edit_count; i++)); do
        sorted_indices+=("$i")
    done

    # Insertion sort ascending by start position
    for ((i = 1; i < edit_count; i++)); do
        local key=${sorted_indices[$i]}
        local key_start=${starts[$key]}
        local j=$((i - 1))
        while ((j >= 0 && starts[sorted_indices[j]] > key_start)); do
            sorted_indices[$((j + 1))]=${sorted_indices[$j]}
            j=$((j - 1))
        done
        sorted_indices[$((j + 1))]=$key
    done

    # Build the result by concatenating segments from the original content.
    # Because we validated positions against the original and iterate in
    # ascending order, each segment boundary is guaranteed to be correct.
    local result=""
    local pos=0

    for idx in "${sorted_indices[@]}"; do
        local s=${starts[$idx]}
        local e=${ends[$idx]}

        # Append content from current position up to the start of this edit
        local seg_len=$((s - pos))
        if ((seg_len > 0)); then
            result+="${content:$pos:$seg_len}"
        fi
        # Append the replacement text
        result+="${new_texts[$idx]}"
        # Advance past the replaced region
        pos=$e
    done

    # Append the tail of the file
    if ((pos < ${#content})); then
        result+="${content:$pos}"
    fi

    # Atomic write to the target file
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/baish_edit.XXXXXX")

    printf '%s' "$result" > "$tmpfile"

    # Preserve original file permissions
    local mode
    mode=$(stat -c '%a' "$path")
    chmod "$mode" "$tmpfile"

    mv -- "$tmpfile" "$path"

    baish_tool_success_json "edit" "$(jq -n \
        --arg path "$path" \
        --argjson changes "$edit_count" \
        '{"path": $path, "changes_count": $changes}')"
}

# ============================================================
# Bash tool
# ============================================================

# Bash tool
# Executes a shell command in the launch directory with inherited environment.
# Arguments (JSON):
#   command - shell command to execute (required)
#   env     - optional object of env var overrides
# Respects BAISH_BASH_TIMEOUT (default: 120s) to prevent runaway processes.
# Commands execute automatically without confirmation.
baish_tool_bash() {
    local args_json="$1"
    local command env_json

    command=$(echo "$args_json" | jq -r '.command // empty')
    if [[ -z "$command" ]]; then
        baish_tool_error_json "bash" "MISSING_COMMAND" "The 'command' arg is required"
        return 0
    fi

    # Extract optional env overrides
    env_json=$(echo "$args_json" | jq -c '.env // {}')

    # Build the execution environment: inherit current env, apply overrides
    local launch_dir="${BAISH_LAUNCH_DIR:-$PWD}"

    # Create a temporary script that sets env vars then runs the command
    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/baish_bash.XXXXXX.sh")

    # Write env exports and command to the temp script
    {
        printf '#!/usr/bin/env bash\n'
        # Change to the launch directory
        printf 'cd %q\n' "$launch_dir"
        # Apply env overrides
        local env_keys
        env_keys=$(echo "$env_json" | jq -r 'keys[]')
        for key in $env_keys; do
            local val
            val=$(echo "$env_json" | jq -r ".[\"${key}\"]")
            printf 'export %s=%q\n' "$key" "$val"
        done
        # Execute the command
        printf '%s\n' "$command"
    } > "$tmpscript"
    chmod +x "$tmpscript"

    # Capture stdout and stderr separately
    local stdout_file stderr_file
    stdout_file=$(mktemp "${TMPDIR:-/tmp}/baish_stdout.XXXXXX")
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/baish_stderr.XXXXXX")

    local exit_code=0
    local timed_out=false

    # Run with timeout
    if command -v timeout &>/dev/null; then
        timeout --signal=KILL "${BAISH_BASH_TIMEOUT}" bash "$tmpscript" \
            >"$stdout_file" 2>"$stderr_file" || exit_code=$?
        # timeout returns 137 (128+9) when it kills the process
        if [[ "$exit_code" -eq 137 ]]; then
            timed_out=true
        fi
    else
        # Fallback: use bash background job + wait with timeout
        bash "$tmpscript" >"$stdout_file" 2>"$stderr_file" &
        local cmd_pid=$!
        local waited=0
        while kill -0 "$cmd_pid" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
            if (( waited >= BAISH_BASH_TIMEOUT )); then
                kill -9 "$cmd_pid" 2>/dev/null
                wait "$cmd_pid" 2>/dev/null
                timed_out=true
                exit_code=137
                break
            fi
        done
        if [[ "$timed_out" == "false" ]]; then
            wait "$cmd_pid" 2>/dev/null
            exit_code=$?
        fi
    fi

    # Clean up temp script
    rm -f "$tmpscript"

    # Read output (truncate to avoid excessive JSON payloads)
    local stdout_content stderr_content
    local max_output_bytes=65536  # 64KB limit per stream

    stdout_content=$(head -c "$max_output_bytes" "$stdout_file" 2>/dev/null)
    stderr_content=$(head -c "$max_output_bytes" "$stderr_file" 2>/dev/null)

    rm -f "$stdout_file" "$stderr_file"

    # Build result JSON
    if [[ "$timed_out" == "true" ]]; then
        baish_tool_error_json "bash" "TIMEOUT" \
            "Command timed out after ${BAISH_BASH_TIMEOUT}s. stdout: ${stdout_content} stderr: ${stderr_content}"
    else
        baish_tool_success_json "bash" "$(jq -n \
            --arg stdout "$stdout_content" \
            --arg stderr "$stderr_content" \
            --argjson exit_code "$exit_code" \
            '{"stdout": $stdout, "stderr": $stderr, "exit_code": $exit_code}')"
    fi
}
