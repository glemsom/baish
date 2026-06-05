#!/usr/bin/env bash
# BAISH — Agent conversation loop

source "${BASH_SOURCE%/*}/config.sh"
source "${BASH_SOURCE%/*}/session.sh"
source "${BASH_SOURCE%/*}/display.sh"
source "${BASH_SOURCE%/*}/errors.sh"

# Run the agent loop for a single user message
baish_agent_run_user_message() {
    local user_text="$1"

    baish_debug_state "idle" "processing" "user message received"
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
        local tools_json
        tools_json=$(baish_tool_schemas)
        local request_json
        request_json=$(baish_session_build_request "${tools_json}")

        # Call the provider
        local response_json stderr_content stderr_file
        stderr_file="${BAISH_CHAT_STDERR_FILE:-/tmp/baish_chat_stderr.$$}"
        response_json=$(baish_agent_provider_chat_capture "${request_json}")
        local exit_code=$?
        stderr_content=$(cat "${stderr_file}" 2>/dev/null || echo "")

        if (( exit_code != 0 )); then
            baish_debug_state "processing" "error" "provider exit code ${exit_code}"
            if ! baish_handle_provider_error "${stderr_content}" "${BAISH_CURRENT_PROVIDER}"; then
                break
            fi
            break
        fi

        baish_debug_state "chat_sent" "chat_received" "provider=${BAISH_CURRENT_PROVIDER}"

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

            baish_debug_tool "${tool_name}" "id=${tool_id}"

            # Execute the tool
            local result_json
            result_json=$(baish_tool_execute "${tool_name}" "${tool_args}")

            # Append tool result to session
            baish_session_append_tool_result "${tool_id}" "${result_json}"

            # Display tool result summary
            local ok status_msg err_msg
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
                err_msg=$(echo "${result_json}" | jq -r '.error.message')
                baish_print_tool_result "❌" "${tool_name}: ${err_msg}"
            fi

            # Log debug summary (after ok/err_msg are set)
            if [[ "${ok}" == "true" ]]; then
                baish_debug_tool "${tool_name}" "id=${tool_id}" "success"
            else
                baish_debug_tool "${tool_name}" "id=${tool_id}" "error: ${err_msg:-unknown}"
            fi

            BAISH_SESSION_TOTAL_TOOL_CALLS=$(( BAISH_SESSION_TOTAL_TOOL_CALLS + 1 ))
        done

        BAISH_SESSION_TOOL_ROUNDS=$(( BAISH_SESSION_TOOL_ROUNDS + 1 ))
    done
}

# Call provider chat, capturing output with a thinking spinner.
# Captures stdout (response JSON) and stderr (error signals) separately.
# Writes stderr to BAISH_CHAT_STDERR_FILE for the caller to analyze.
# If BAISH_CHAT_STDERR_FILE is set, writes stderr there; otherwise
# writes to /tmp/baish_chat_stderr.$$ and cleans up.
baish_agent_provider_chat_capture() {
    local request_json="$1"

    # Extract messages and tools
    local messages tools_json
    messages=$(echo "${request_json}" | jq -c '.messages')
    tools_json=$(echo "${request_json}" | jq -c '.tools // []')

    baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "" "sending request"

    # Use a persistent temp file so stderr survives the subshell
    local stderr_file="${BAISH_CHAT_STDERR_FILE:-/tmp/baish_chat_stderr.$$}"

    # Show thinking spinner in background (only if stderr is a terminal)
    local spinner_pid=""
    if [[ -t 2 ]]; then
        baish_print_thinking_bg &
        spinner_pid=$!
    fi

    # Call provider chat function directly, capturing stderr to file
    local chat_fn="provider_${BAISH_CURRENT_PROVIDER}_chat"
    local result
    result=$(${chat_fn} "${messages}" "${tools_json}" 2>"${stderr_file}")
    local exit_code=$?

    # Kill spinner
    if [[ -n "${spinner_pid}" ]]; then
        kill "${spinner_pid}" 2>/dev/null
        wait "${spinner_pid}" 2>/dev/null
        printf "\r                              \r"
    fi

    if (( exit_code != 0 )); then
        baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "${exit_code}" "error"
        return "${exit_code}"
    fi

    baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "200" "response received"
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
