#!/usr/bin/env bash
# shellcheck disable=SC2154
# ── lib/agent.sh — Multi-turn agent loop ───────────────────────────
# Requires: config.sh, tui.sh, prompt.sh, tools.sh, api.sh sourced first
# Cross-file variables: _system_prompt, _tools_json, _tui_*, _agent_*

# shellcheck source=./lib/tui.sh
# shellcheck source=./lib/prompt.sh
# shellcheck source=./lib/tools.sh
# shellcheck source=./lib/api.sh
# shellcheck source=./lib/config.sh

# ── Conversation state ─────────────────────────────────────────────
_AGENT_MESSAGES_FILE=""
_AGENT_TOKEN_COUNT=0

# ── Initialize conversation ────────────────────────────────────────
# Must be called before agent_loop(). Sets up temp file with system prompt.
agent_init() {
    _AGENT_MESSAGES_FILE=$(mktemp /tmp/baish_messages.XXXXXX)
    _AGENT_TOKEN_COUNT=0

    # Trap cleanup on exit
    trap '_agent_cleanup' EXIT

    # Write system message as the first entry
    local system_msg
    system_msg=$(jq -n \
        --arg content "$_system_prompt" \
        '[{role: "system", content: $content}]')

    echo "$system_msg" > "$_AGENT_MESSAGES_FILE"

    _AGENT_TOKEN_COUNT=$(api_estimate_tokens "$_system_prompt")
}

# ── Cleanup ────────────────────────────────────────────────────────
_agent_cleanup() {
    # Kill any leftover spinner background process
    tui_spinner_stop
    # Clean up temp messages file
    if [[ -n "$_AGENT_MESSAGES_FILE" && -f "$_AGENT_MESSAGES_FILE" ]]; then
        rm -f "$_AGENT_MESSAGES_FILE"
    fi
}

# ── Append a message to conversation history ───────────────────────
# Args: role  content
# Appends {role, content} to the messages JSON array in the temp file.
agent_append_message() {
    local role="$1"
    local content="$2"

    local new_msg
    new_msg=$(jq -n --arg role "$role" --arg content "$content" \
        '{role: $role, content: $content}')

    local current
    current=$(cat "$_AGENT_MESSAGES_FILE")

    # Append to the array
    echo "$current" | jq --argjson msg "$new_msg" '. + [$msg]' > "$_AGENT_MESSAGES_FILE"

    # Update token count
    _AGENT_TOKEN_COUNT=$(( _AGENT_TOKEN_COUNT + $(api_estimate_tokens "$content") ))
}

# ── Append tool result to conversation ─────────────────────────────
# Args: tool_call_id  tool_name  result_text
# Appends {role: "tool", tool_call_id, name, content} to messages.
agent_append_tool_result() {
    local tool_call_id="$1"
    local tool_name="$2"
    local result_text="$3"

    local new_msg
    new_msg=$(jq -n \
        --arg role "tool" \
        --arg tc_id "$tool_call_id" \
        --arg name "$tool_name" \
        --arg content "$result_text" \
        '{role: $role, tool_call_id: $tc_id, name: $name, content: $content}')

    local current
    current=$(cat "$_AGENT_MESSAGES_FILE")

    echo "$current" | jq --argjson msg "$new_msg" '. + [$msg]' > "$_AGENT_MESSAGES_FILE"

    # Update token count
    _AGENT_TOKEN_COUNT=$(( _AGENT_TOKEN_COUNT + $(api_estimate_tokens "$result_text") ))
}

# ── Append assistant message with tool_calls ───────────────────────
# Args: text_content (may be empty)  tool_calls_json
# Appends the full assistant message to history.
agent_append_assistant() {
    local text_content="$1"
    local tool_calls_json="$2"

    local current
    current=$(cat "$_AGENT_MESSAGES_FILE")

    if [[ -n "$tool_calls_json" && "$tool_calls_json" != "[]" ]]; then
        # Message with tool_calls
        if [[ -n "$text_content" ]]; then
            echo "$current" | jq \
                --arg content "$text_content" \
                --argjson tool_calls "$tool_calls_json" \
                '. + [{role: "assistant", content: $content, tool_calls: $tool_calls}]' \
                > "$_AGENT_MESSAGES_FILE"
        else
            echo "$current" | jq \
                --argjson tool_calls "$tool_calls_json" \
                '. + [{role: "assistant", content: null, tool_calls: $tool_calls}]' \
                > "$_AGENT_MESSAGES_FILE"
        fi
    else
        # Plain text message
        echo "$current" | jq \
            --arg content "$text_content" \
            '. + [{role: "assistant", content: $content}]' \
            > "$_AGENT_MESSAGES_FILE"
    fi

    # Update token count
    local total_text="$text_content"
    if [[ -n "$tool_calls_json" && "$tool_calls_json" != "[]" ]]; then
        total_text+="$tool_calls_json"
    fi
    _AGENT_TOKEN_COUNT=$(( _AGENT_TOKEN_COUNT + $(api_estimate_tokens "$total_text") ))
}

# ── Get current messages as JSON ───────────────────────────────────
# Returns: full messages JSON array (reads from temp file)
agent_get_messages() {
    cat "$_AGENT_MESSAGES_FILE"
}

# ── Trim messages if over token budget ─────────────────────────────
# Calls api_trim_messages and writes result back to the temp file.
agent_maybe_trim() {
    local max_tokens="${BAISH_MAX_CONTEXT:-32000}"

    if [[ $_AGENT_TOKEN_COUNT -gt $(( (max_tokens * 80) / 100 )) ]]; then
        local messages
        messages=$(cat "$_AGENT_MESSAGES_FILE")

        local trimmed
        trimmed=$(api_trim_messages "$messages" "$max_tokens")

        echo "$trimmed" > "$_AGENT_MESSAGES_FILE"

        # Recalculate token count from trimmed messages
        _AGENT_TOKEN_COUNT=0
        local count
        count=$(echo "$trimmed" | jq 'length')
        local i
        for (( i = 0; i < count; i++ )); do
            local content
            content=$(echo "$trimmed" | jq -r ".[$i].content // \"\"")
            local tool_calls_str
            tool_calls_str=$(echo "$trimmed" | jq -c ".[$i].tool_calls // []" 2>/dev/null)
            _AGENT_TOKEN_COUNT=$(( _AGENT_TOKEN_COUNT + $(api_estimate_tokens "$content") + $(api_estimate_tokens "$tool_calls_str") ))
        done
    fi
}

# ── Build a summary of tool call args for display ──────────────────
# Args: tool_call_json (single tool call object)
# Returns: short string like "shell(command='ls -la')"
_agent_args_summary() {
    local tool_call_json="$1"
    local name args_str

    name=$(echo "$tool_call_json" | jq -r '.function.name')
    args_str=$(echo "$tool_call_json" | jq -r '.function.arguments | to_entries | map("\(.key)=\(.value | tostring | .[0:40])") | join(", ")')

    echo "${name}(${args_str})"
}

# ── Execute a single tool call ─────────────────────────────────────
# Args: tool_call_json (single object from tool_calls array)
# Returns: tool result text on stdout
_agent_exec_tool_call() {
    local tool_call_json="$1"
    local tool_id tool_name tool_args

    tool_id=$(echo "$tool_call_json" | jq -r '.id')
    tool_name=$(echo "$tool_call_json" | jq -r '.function.name')
    tool_args=$(echo "$tool_call_json" | jq -r '.function.arguments')

    # Validate args is valid JSON
    if ! echo "$tool_args" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON arguments for tool $tool_name"
        return 1
    fi

    tools_execute "$tool_name" "$tool_args"
}

# ── Main agent loop ────────────────────────────────────────────────
# This is the core multi-turn loop:
#   1. Send messages + tools to API
#   2. Handle text response or tool calls
#   3. Loop until no more tool calls
#   4. Return to user prompt
#   5. Read user input, repeat
agent_loop() {
    agent_init

    # Lookup actual model context from provider
    local resolved_context
    resolved_context=$(api_lookup_model_context)
    if [[ "$resolved_context" != "$BAISH_MAX_CONTEXT" ]]; then
        BAISH_MAX_CONTEXT="$resolved_context"
    fi

    while true; do
        tui_prompt
        if ! read -r user_input; then
            echo ""
            break
        fi

        # Handle exit commands
        case "$user_input" in
            quit|exit)
                echo -e "  ${_tui_bold}Goodbye!${_tui_reset}"
                break
                ;;
            "")
                continue
                ;;
        esac

        # Append user message to history
        agent_append_message "user" "$user_input"

        # Check token budget before sending
        agent_maybe_trim

        # ── AI interaction loop (handles tool call chains) ──────
        local has_tool_calls=true

        while $has_tool_calls; do
            has_tool_calls=false

            # Get current messages and tools JSON
            local messages_json
            messages_json=$(agent_get_messages)

            # Show spinner
            tui_spinner_start "Thinking..."

            # Call the API
            local api_response
            api_response=$(api_chat "$messages_json" "$_tools_json")
            local api_status=$?

            tui_spinner_stop

            if [[ $api_status -ne 0 ]]; then
                echo -e "  ${_tui_red}Error: API call failed.${_tui_reset}"
                break
            fi

            # Extract response text and tool calls
            local response_text
            response_text=$(api_extract_text "$api_response")

            local tool_calls
            tool_calls=$(api_extract_tool_calls "$api_response")

            # Check if there are tool calls
            local tool_count
            tool_count=$(echo "$tool_calls" | jq 'length' 2>/dev/null) || tool_count=0

            if [[ "$tool_count" -gt 0 ]]; then
                has_tool_calls=true

                # Append assistant message with tool_calls to history
                agent_append_assistant "$response_text" "$tool_calls"

                # Execute each tool call
                local i
                for (( i = 0; i < tool_count; i++ )); do
                    local single_call
                    single_call=$(echo "$tool_calls" | jq -c ".[$i]")

                    local tool_id tool_name
                    tool_id=$(echo "$single_call" | jq -r '.id')
                    tool_name=$(echo "$single_call" | jq -r '.function.name')

                    # Display tool execution
                    local args_summary
                    args_summary=$(_agent_args_summary "$single_call")
                    tui_tool_start "$tool_name" "$args_summary"

                    # Execute the tool
                    tui_spinner_start "▸ $tool_name ..."
                    local tool_result
                    tool_result=$(_agent_exec_tool_call "$single_call") || tool_result="Error executing tool $tool_name"
                    tui_spinner_stop

                    tui_tool_done

                    # Append tool result to history
                    agent_append_tool_result "$tool_id" "$tool_name" "$tool_result"
                done

                # Loop back to send tool results to the API
                continue
            fi

            # No tool calls — display the text response
            if [[ -n "$response_text" ]]; then
                # Append assistant message to history
                agent_append_assistant "$response_text" ""

                # Print response
                echo ""
                tui_print "$response_text"
                echo ""
            fi
        done

        # Check for token budget overflow after the turn
        agent_maybe_trim
    done
}
