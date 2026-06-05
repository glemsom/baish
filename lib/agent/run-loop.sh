#!/usr/bin/env bash
# BAISH — Agent conversation loop

source "${BASH_SOURCE%/*}/config.sh"
source "${BASH_SOURCE%/*}/session.sh"
source "${BASH_SOURCE%/*}/display.sh"

# Run the agent loop for a single user message
baish_agent_run_user_message() {
    local user_text="$1"

    baish_session_append_user_message "${user_text}"
    BAISH_SESSION_TOOL_ROUNDS=0

    # Tool call loop
    while true; do
        # Check limits
        if (( BAISH_SESSION_TOOL_ROUNDS >= BAISH_MAX_TOOL_ROUNDS )); then
            baish_print_info "Max tool rounds reached (${BAISH_MAX_TOOL_ROUNDS}). Stopping."
            break
        fi

        if (( BAISH_SESSION_TOTAL_TOOL_CALLS >= BAISH_MAX_TOOL_CALLS )); then
            baish_print_info "Max total tool calls reached (${BAISH_MAX_TOOL_CALLS}). Stopping."
            break
        fi

        # Build request with tools
        local tools_json="[]"
        local request_json
        request_json=$(baish_session_build_request "${tools_json}")

        # Call the provider
        local response_json
        response_json=$(baish_agent_provider_chat_capture "${request_json}")
        local exit_code=$?

        if (( exit_code != 0 )); then
            baish_print_error "Provider chat failed (exit code: ${exit_code})"
            break
        fi

        local assistant_text tool_calls
        assistant_text=$(echo "${response_json}" | jq -r '.assistant_text // ""')
        tool_calls=$(echo "${response_json}" | jq -c '.tool_calls // []')

        # Display assistant text (only on first round)
        if (( BAISH_SESSION_TOOL_ROUNDS == 0 )); then
            if [[ -n "${assistant_text}" ]]; then
                baish_print_assistant_response "${assistant_text}"
            fi
        fi

        # Save assistant response
        baish_session_append_assistant_response "${assistant_text}" "${tool_calls}"

        # Check for tool calls
        local tool_count
        tool_count=$(echo "${tool_calls}" | jq 'length')

        if (( tool_count == 0 )); then
            break
        fi

        # Execute tool calls sequentially
        local tc_idx
        for (( tc_idx = 0; tc_idx < tool_count; tc_idx++ )); do
            if (( BAISH_SESSION_TOTAL_TOOL_CALLS >= BAISH_MAX_TOOL_CALLS )); then
                baish_print_info "Max total tool calls reached (${BAISH_MAX_TOOL_CALLS}). Stopping."
                break 2
            fi

            local tc
            tc=$(echo "${tool_calls}" | jq -c ".[$tc_idx]")
            local tool_id tool_name tool_args
            tool_id=$(echo "${tc}" | jq -r '.id')
            tool_name=$(echo "${tc}" | jq -r '.name')
            tool_args=$(echo "${tc}" | jq -r '.arguments')

            baish_debug "Executing tool: ${tool_name} (id: ${tool_id})"

            # Execute the tool
            local result_json
            result_json=$(baish_tool_execute "${tool_name}" "${tool_args}")

            # Append tool result to session
            baish_session_append_tool_result "${tool_id}" "${result_json}"

            # Display tool result summary
            local ok status_msg
            ok=$(echo "${result_json}" | jq -r '.ok')
            if [[ "${ok}" == "true" ]]; then
                local tool_icon
                case "${tool_name}" in
                    read) tool_icon="${BAISH_ICON_READ}" ;;
                    write) tool_icon="${BAISH_ICON_WRITE}" ;;
                    edit) tool_icon="${BAISH_ICON_EDIT}" ;;
                    bash) tool_icon="${BAISH_ICON_BASH}" ;;
                    *) tool_icon="🔧" ;;
                esac
                if [[ "${tool_name}" == "bash" ]]; then
                    local bash_stdout bash_stderr bash_exit_code
                    bash_stdout=$(echo "${result_json}" | jq -r '.data.stdout // ""')
                    bash_stderr=$(echo "${result_json}" | jq -r '.data.stderr // ""')
                    bash_exit_code=$(echo "${result_json}" | jq -r '.data.exit_code // 0')
                    baish_print_bash_output "${tool_icon}" "${bash_stdout}" "${bash_stderr}" "${bash_exit_code}"
                else
                    status_msg="${tool_name}: completed"
                    baish_print_tool_result "${tool_icon}" "${status_msg}"
                fi
            else
                local err_msg
                err_msg=$(echo "${result_json}" | jq -r '.error.message')
                baish_print_tool_result "❌" "${tool_name}: ${err_msg}"
            fi

            BAISH_SESSION_TOTAL_TOOL_CALLS=$(( BAISH_SESSION_TOTAL_TOOL_CALLS + 1 ))
        done

        BAISH_SESSION_TOOL_ROUNDS=$(( BAISH_SESSION_TOOL_ROUNDS + 1 ))
    done
}

# Call provider chat, capturing output with a thinking spinner
baish_agent_provider_chat_capture() {
    local request_json="$1"

    # Extract messages and tools
    local messages tools_json
    messages=$(echo "${request_json}" | jq -c '.messages')
    tools_json=$(echo "${request_json}" | jq -c '.tools // []')

    # Show thinking spinner in background (only if stderr is a terminal)
    local spinner_pid=""
    if [[ -t 2 ]]; then
        baish_print_thinking_bg &
        spinner_pid=$!
    fi

    # Call provider chat function directly
    local chat_fn="provider_${BAISH_CURRENT_PROVIDER}_chat"
    local result
    result=$(${chat_fn} "${messages}" "${tools_json}" 2>/dev/null)
    local exit_code=$?

    # Kill spinner
    if [[ -n "${spinner_pid}" ]]; then
        kill "${spinner_pid}" 2>/dev/null
        wait "${spinner_pid}" 2>/dev/null
        printf "\r                              \r"
    fi

    if (( exit_code != 0 )); then
        return "${exit_code}"
    fi

    echo "${result}"
    return 0
}

# Background spinner function (prints to stderr so it doesn't pollute stdout)
baish_print_thinking_bg() {
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
        printf "\r${BAISH_COLOR_CYAN}  %s thinking...${BAISH_COLOR_RESET}" "${chars[$i]}" >&2
        i=$(( (i + 1) % ${#chars[@]} ))
        sleep 0.1
    done
}
