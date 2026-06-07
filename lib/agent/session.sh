#!/usr/bin/env bash
# BAISH — Session management (in-memory message history)

# Session arrays
BAISH_SESSION_MESSAGES=()
BAISH_SESSION_SKILL_NAMES=()
BAISH_SESSION_SKILL_CONTENTS=()

# All available skill names (populated at startup by baish_skill_scan_available)
# Used by TAB completion for /skill: prefix
BAISH_AVAILABLE_SKILL_NAMES=()

# Provider selection
BAISH_CURRENT_PROVIDER=""
BAISH_CURRENT_MODEL=""

# Session state
BAISH_SESSION_EXIT_REQUESTED=0
BAISH_SESSION_TOOL_ROUNDS=0

# Reset conversation context (keeps provider, model, skills)
baish_session_reset_context_window() {
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_TOOL_ROUNDS=0
    baish_debug "Session context cleared"
}

# Append a user message to the session
baish_session_append_user_message() {
    local text="$1"
    local msg
    # Use stdin (not --arg) to avoid ARG_MAX when text is large
    msg=$(printf '%s' "${text}" | jq -Rsc '{role: "user", content: .}')
    BAISH_SESSION_MESSAGES+=("${msg}")
    baish_debug "User message appended (total messages: ${#BAISH_SESSION_MESSAGES[@]})"
}

# Append an assistant response to the session.
# Tool calls are normalized to OpenAI format (with function wrapper) so that
# subsequent API requests pass validation. The provider response uses a
# flattened internal format ({id, name, arguments}) which must be
# converted back to the API format ({id, type: "function", function: {name, arguments}}).
baish_session_append_assistant_response() {
    local text="$1"
    local tool_calls_json="$2"

    # Normalize tool_calls to OpenAI format (idempotent — if already wrapped, pass through)
    local normalized_tc
    normalized_tc=$(echo "${tool_calls_json}" | jq -c '
        if . == null or . == [] then []
        else [.[] |
            if has("function") then .
            else {
                "id": .id,
                "type": "function",
                "function": {
                    "name": .name,
                    "arguments": .arguments
                }
            } end
        ] end
    ')

    local msg
    # Use stdin for text (can be large); tool_calls stays as argjson (small)
    msg=$(printf '%s' "${text}" | jq -Rsc --argjson tc "${normalized_tc}" \
        '{role: "assistant", content: ., tool_calls: $tc}')
    BAISH_SESSION_MESSAGES+=("${msg}")
    baish_debug "Assistant response appended (total messages: ${#BAISH_SESSION_MESSAGES[@]})"
}

# Append a tool result to the session.
# The OpenAI API requires the content field to be a string, so we JSON-encode
# the result object before storing it.
baish_session_append_tool_result() {
    local tool_call_id="$1"
    local result_json="$2"

    # Convert result JSON to a string (OpenAI API requires string content)
    local content_str
    content_str=$(echo "${result_json}" | jq -c '.')

    local msg
    # Use stdin for content_str (can be large — tool outputs); small args stay as --arg
    msg=$(printf '%s' "${content_str}" | jq -Rsc --arg tool_call_id "${tool_call_id}" \
        '{role: "tool", tool_call_id: $tool_call_id, content: .}')
    BAISH_SESSION_MESSAGES+=("${msg}")
    baish_debug "Tool result appended (total messages: ${#BAISH_SESSION_MESSAGES[@]})"
}

# Build the full request JSON (system + skills + messages)
baish_session_build_request() {
    local tools_json="$1"
    local system_prompt="${BAISH_SYSTEM_PROMPT:-You are BAISH, a Bash-first terminal AI coding agent.}"

    # Append skill catalog to system prompt if available
    local skill_catalog
    skill_catalog=$(baish_skill_get_catalog)
    if [[ -n "${skill_catalog}" ]]; then
        system_prompt="${system_prompt}"$'\n\n'"${skill_catalog}"$'\n\n'"Load a skill with /skill:<name> or by using the read tool on its SKILL.md path."
    fi

    # Build the messages array starting with system message
    local full_messages
    # Use stdin for system_prompt (can be large with custom prompts)
    full_messages=$(printf '%s' "${system_prompt}" | jq -Rsc '[{"role": "system", "content": .}]')

    # Add skill system messages
    # Use process substitution to avoid ARG_MAX — both full_messages (growing)
    # and skill_content (potentially large SKILL.md files) flow through file
    # descriptors, never as command-line arguments.
    local i
    for i in "${!BAISH_SESSION_SKILL_CONTENTS[@]}"; do
        local skill_content="${BAISH_SESSION_SKILL_CONTENTS[$i]}"
        full_messages=$(jq -s '.[0] + [{"role": "system", "content": .[1]}]' \
            <(echo "${full_messages}") \
            <(printf '%s' "${skill_content}" | jq -Rsc '.'))
    done

    # Inject AGENTS.md content as a user message between skills and conversation
    local agents_content
    agents_content=$(baish_agents_md_get_content)
    if [[ -n "${agents_content}" ]]; then
        full_messages=$(jq -s '.[0] + [{"role": "user", "content": .[1]}]' \
            <(echo "${full_messages}") \
            <(printf '%s' "${agents_content}" | jq -Rsc '.'))
    fi

    # Append conversation messages
    # Process substitution avoids ARG_MAX: both full_messages (growing) and
    # individual msg (can be large tool results) go through /dev/fd, not argv.
    local msg
    for msg in "${BAISH_SESSION_MESSAGES[@]}"; do
        full_messages=$(jq -s '.[0] + [.[1]]' \
            <(echo "${full_messages}") \
            <(echo "${msg}"))
    done

    # Final assembly: pipe full_messages via stdin (can be huge),
    # tools_json via --argjson (always small — tool schema array).
    echo "${full_messages}" | jq --argjson tools "${tools_json}" \
        '{messages: ., tools: $tools}'
}
