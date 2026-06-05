#!/usr/bin/env bash
# BAISH — Session management (in-memory message history)

# Session arrays
BAISH_SESSION_MESSAGES=()
BAISH_SESSION_SKILL_NAMES=()
BAISH_SESSION_SKILL_CONTENTS=()

# Provider selection
BAISH_CURRENT_PROVIDER=""
BAISH_CURRENT_MODEL=""

# Session state
BAISH_SESSION_EXIT_REQUESTED=0
BAISH_SESSION_TOOL_ROUNDS=0
BAISH_SESSION_TOTAL_TOOL_CALLS=0

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
    msg=$(jq -n --arg role "user" --arg content "${text}" '{"role": $role, "content": $content}')
    BAISH_SESSION_MESSAGES+=("${msg}")
    baish_debug "User message appended (total messages: ${#BAISH_SESSION_MESSAGES[@]})"
}

# Append an assistant response to the session
baish_session_append_assistant_response() {
    local text="$1"
    local tool_calls_json="$2"
    local msg
    msg=$(jq -n --arg role "assistant" --arg content "${text}" --argjson tc "${tool_calls_json}" \
        '{"role": $role, "content": $content, "tool_calls": $tc}')
    BAISH_SESSION_MESSAGES+=("${msg}")
    baish_debug "Assistant response appended (total messages: ${#BAISH_SESSION_MESSAGES[@]})"
}

# Append a tool result to the session
baish_session_append_tool_result() {
    local tool_call_id="$1"
    local result_json="$2"
    local msg
    msg=$(jq -n --arg role "tool" --arg tool_call_id "${tool_call_id}" --argjson content "${result_json}" \
        '{"role": $role, "tool_call_id": $tool_call_id, "content": $content}')
    BAISH_SESSION_MESSAGES+=("${msg}")
    baish_debug "Tool result appended (total messages: ${#BAISH_SESSION_MESSAGES[@]})"
}

# Build the full request JSON (system + skills + messages)
baish_session_build_request() {
    local tools_json="$1"
    local system_prompt="${BAISH_SYSTEM_PROMPT:-You are BAISH, a Bash-first terminal AI coding agent.}"

    # Build the messages array starting with system message
    local full_messages
    full_messages=$(jq -n --arg content "${system_prompt}" '[{"role": "system", "content": $content}]')

    # Add skill system messages
    local i
    for i in "${!BAISH_SESSION_SKILL_CONTENTS[@]}"; do
        local skill_content="${BAISH_SESSION_SKILL_CONTENTS[$i]}"
        full_messages=$(echo "${full_messages}" | jq --arg content "${skill_content}" '. + [{"role": "system", "content": $content}]')
    done

    # Append conversation messages
    local msg
    for msg in "${BAISH_SESSION_MESSAGES[@]}"; do
        full_messages=$(echo "${full_messages}" | jq --argjson m "${msg}" '. + [$m]')
    done

    jq -n --argjson messages "${full_messages}" --argjson tools "${tools_json}" \
        '{"messages": $messages, "tools": $tools}'
}
