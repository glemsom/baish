#!/usr/bin/env bash
# ── lib/tools.sh — Tool registration, definitions, and execution ────
# Requires: config.sh sourced first (BAISH_SKILLS_DIR)

# ── Tool registry ──────────────────────────────────────────────────
declare -a TOOL_NAMES=()
declare -A TOOL_DESCRIPTIONS=()
declare -A TOOL_PARAMS=()
declare -A TOOL_PROMPT_TEXTS=()

# ── Registration ────────────────────────────────────────────────────
register_tool() {
    local name="$1"
    local description="$2"
    local params_json="$3"
    local prompt_text="$4"
    TOOL_NAMES+=("$name")
    TOOL_DESCRIPTIONS["$name"]="$description"
    TOOL_PARAMS["$name"]="$params_json"
    TOOL_PROMPT_TEXTS["$name"]="$prompt_text"
}

# ── Tool: shell ────────────────────────────────────────────────────
register_tool \
    "shell" \
    "Execute a shell command. Output is auto-compressed by lean-ctx." \
    '{
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "Bash command to execute"
            }
        },
        "required": ["command"]
    }' \
    "shell <command>: Run a shell command. Use lean-ctx tools (ctx_read, ctx_ls, ctx_find, ctx_grep) when available."

execute_shell() {
    local args_json="$1"
    local command
    command=$(echo "$args_json" | jq -r '.command')
    if [[ -z "$command" ]]; then
        echo "Error: 'command' argument is required for shell tool."
        return 1
    fi

    local output
    output=$(eval "$command" 2>&1) || true

    # Compress output with lean-ctx if available
    if command -v lean-ctx &>/dev/null; then
        echo "$output" | lean-ctx -c 2>/dev/null || echo "$output"
    else
        # Simple truncation fallback
        echo "$output"
    fi
}

# ── Tool: read ─────────────────────────────────────────────────────
register_tool \
    "read" \
    "Read file contents. Auto-selects mode: configs are full-read, code files use smart mode." \
    '{
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Path to the file to read (relative or absolute)"
            }
        },
        "required": ["path"]
    }' \
    "read <path>: Read file contents. Always use this before editing a file."

execute_read() {
    local args_json="$1"
    local path
    path=$(echo "$args_json" | jq -r '.path')
    if [[ -z "$path" ]]; then
        echo "Error: 'path' argument is required for read tool."
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        echo "Error: File not found: $path"
        return 1
    fi

    local output
    output=$(cat "$path" 2>&1) || { echo "Error: Could not read file: $path"; return 1; }

    # Compress with lean-ctx if available
    if command -v lean-ctx &>/dev/null; then
        echo "$output" | lean-ctx -c 2>/dev/null || echo "$output"
    else
        echo "$output"
    fi
}

# ── Tool: write ────────────────────────────────────────────────────
register_tool \
    "write" \
    "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories." \
    '{
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Path to the file to write (relative or absolute)"
            },
            "content": {
                "type": "string",
                "description": "Content to write to the file"
            }
        },
        "required": ["path", "content"]
    }' \
    "write <path> <content>: Write content to a file. Creates parent directories automatically."

execute_write() {
    local args_json="$1"
    local path content
    path=$(echo "$args_json" | jq -r '.path')
    content=$(echo "$args_json" | jq -r '.content')

    if [[ -z "$path" ]]; then
        echo "Error: 'path' argument is required for write tool."
        return 1
    fi

    mkdir -p "$(dirname "$path")" || { echo "Error: Could not create directory for: $path"; return 1; }
    printf '%s' "$content" > "$path" || { echo "Error: Could not write to: $path"; return 1; }
    echo "Wrote $(wc -c < "$path") bytes to $path"
}

# ── Tool: edit ─────────────────────────────────────────────────────
register_tool \
    "edit" \
    "Edit a single file using exact text replacement. Every oldText must match a unique, non-overlapping region." \
    '{
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Path to the file to edit (relative or absolute)"
            },
            "oldText": {
                "type": "string",
                "description": "Exact text to find and replace"
            },
            "newText": {
                "type": "string",
                "description": "Replacement text"
            }
        },
        "required": ["path", "oldText", "newText"]
    }' \
    "edit <path> <oldText> <newText>: Make a targeted edit. oldText must match exactly and uniquely."

execute_edit() {
    local args_json="$1"
    local path oldText newText
    path=$(echo "$args_json" | jq -r '.path')
    oldText=$(echo "$args_json" | jq -r '.oldText')
    newText=$(echo "$args_json" | jq -r '.newText')

    if [[ -z "$path" ]]; then
        echo "Error: 'path' argument is required for edit tool."
        return 1
    fi
    if [[ -z "$oldText" ]]; then
        echo "Error: 'oldText' argument is required for edit tool."
        return 1
    fi
    if [[ -z "$newText" && "$newText" == "" ]]; then
        # Allow empty newText (deletion), but check jq didn't fail
        local has_newText
        has_newText=$(echo "$args_json" | jq 'has("newText")')
        if [[ "$has_newText" != "true" ]]; then
            echo "Error: 'newText' argument is required for edit tool (use empty string to delete)."
            return 1
        fi
    fi

    if [[ ! -f "$path" ]]; then
        echo "Error: File not found: $path"
        return 1
    fi

    local file_content
    file_content=$(cat "$path")

    # Count occurrences of oldText
    local count
    count=$(echo "$file_content" | grep -c -F "$oldText" 2>/dev/null) || count=0

    if [[ $count -eq 0 ]]; then
        echo "Error: oldText not found in file: $path"
        return 1
    fi
    if [[ $count -gt 1 ]]; then
        echo "Error: oldText matches $count locations in $path. Must be unique."
        return 1
    fi

    # Perform the replacement
    local new_content
    new_content="${file_content/"$oldText"/"$newText"}"
    printf '%s' "$new_content" > "$path"
    echo "Edited $path (1 replacement)"
}

# ── Tool: load_skill ───────────────────────────────────────────────
register_tool \
    "load_skill" \
    "Load a skill's full instructions by name. Skills provide：SKILL.md in the skills directory." \
    '{
        "type": "object",
        "properties": {
            "skill_name": {
                "type": "string",
                "description": "Name of the skill to load"
            }
        },
        "required": ["skill_name"]
    }' \
    "load_skill <skill_name>: Load full instructions for a skill. Use when you need detailed guidance."

execute_load_skill() {
    local args_json="$1"
    local skill_name
    skill_name=$(echo "$args_json" | jq -r '.skill_name')

    if [[ -z "$skill_name" ]]; then
        echo "Error: 'skill_name' argument is required for load_skill tool."
        return 1
    fi

    local skills_dir="${BAISH_SKILLS_DIR:-/root/.baish/skills}"
    local skill_path="${skills_dir}/${skill_name}/SKILL.md"

    if [[ ! -f "$skill_path" ]]; then
        echo "Error: Skill not found: $skill_name (expected: $skill_path)"
        return 1
    fi

    cat "$skill_path"
}

# ── Tool dispatch ──────────────────────────────────────────────────
tools_execute() {
    local name="$1"
    local args_json="$2"

    case "$name" in
        shell)      execute_shell "$args_json" ;;
        read)       execute_read "$args_json" ;;
        write)      execute_write "$args_json" ;;
        edit)       execute_edit "$args_json" ;;
        load_skill) execute_load_skill "$args_json" ;;
        *)
            echo "Error: Unknown tool: $name"
            return 1
            ;;
    esac
}

# ── Build OpenAI tool definitions JSON ─────────────────────────────
# Returns: JSON array of tool definitions for the API
tools_build_definitions_json() {
    local result="["
    local first=true
    local name

    for name in "${TOOL_NAMES[@]}"; do
        local desc="${TOOL_DESCRIPTIONS[$name]}"
        local params="${TOOL_PARAMS[$name]}"

        local tool_def
        tool_def=$(jq -n \
            --arg name "$name" \
            --arg desc "$desc" \
            --argjson params "$params" \
            '{
                type: "function",
                function: {
                    name: $name,
                    description: $desc,
                    parameters: $params
                }
            }')

        if $first; then
            result+="$tool_def"
            first=false
        else
            result+=",$tool_def"
        fi
    done
    result+="]"
    echo "$result"
}

# ── Build tool prompt text for system prompt ───────────────────────
# Returns: text block describing available tools (appended to system prompt)
tools_build_prompt_text() {
    local result=""
    local name

    for name in "${TOOL_NAMES[@]}"; do
        local prompt_text="${TOOL_PROMPT_TEXTS[$name]}"
        result+="- ${prompt_text}"$'\n'
    done
    printf '%s' "$result"
}
