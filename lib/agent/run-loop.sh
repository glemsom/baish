#!/usr/bin/env bash
# BAISH — Agent conversation loop

source "${BASH_SOURCE%/*}/config.sh"
source "${BASH_SOURCE%/*}/session.sh"
source "${BASH_SOURCE%/*}/output.sh"
source "${BASH_SOURCE%/*}/errors.sh"

# Run the agent loop for a single user message
baish_agent_run_user_message() {
    local user_text="$1"

    baish_debug_state "idle" "processing" "user message received"
    baish_session_append_user_message "${user_text}"
    BAISH_SESSION_TOOL_ROUNDS=0

    # Initialize the staged progress pipeline
    baish_output_pipeline_init
    baish_output_pipeline_stage "parse"

    # stderr capture file — cleaned up after the loop
    local stderr_file
    stderr_file="${BAISH_CHAT_STDERR_FILE:-/tmp/baish_chat_stderr.$$}"

    # Tool call loop
    while true; do
        # Check limits
        if (( BAISH_SESSION_TOOL_ROUNDS >= BAISH_MAX_TOOL_ROUNDS )); then
            baish_output_info "Max tool rounds reached (${BAISH_MAX_TOOL_ROUNDS}). Stopping."
            break
        fi

        # Build request with tools
        local tools_json
        tools_json=$(baish_tool_schemas)
        local request_json
        request_json=$(baish_session_build_request "${tools_json}")

        # Call the provider
        baish_output_pipeline_stage "think"
        local response_json
        response_json=$(baish_agent_provider_chat_capture "${request_json}")
        local exit_code=$?

        # Infrastructure failure (curl crash, etc.)
        if (( exit_code != 0 )); then
            baish_debug_state "processing" "error" "provider infra exit code ${exit_code}"
            local stderr_content
            stderr_content=$(cat "${stderr_file}" 2>/dev/null || echo "")
            baish_output_error "Provider ${BAISH_CURRENT_PROVIDER} infrastructure failure: ${stderr_content}"
            baish_output_pipeline_stage "error"
            break
        fi

        # Parse structured response — check ok field for provider-level errors
        local ok error_json
        ok=$(echo "${response_json}" | jq -r '.ok // false')

        if [[ "${ok}" != "true" ]]; then
            baish_debug_state "processing" "error" "provider error response"
            error_json=$(echo "${response_json}" | jq -c '.error // {"code": "GENERIC_ERROR", "message": "Unknown"}')
            baish_output_pipeline_stage "error"
            if ! baish_handle_provider_error "${error_json}" "${BAISH_CURRENT_PROVIDER}"; then
                break
            fi
            break
        fi

        baish_debug_state "chat_sent" "chat_received" "provider=${BAISH_CURRENT_PROVIDER}"

        local assistant_text tool_calls
        assistant_text=$(echo "${response_json}" | jq -r '.assistant_text // ""')
        tool_calls=$(echo "${response_json}" | jq -c '.tool_calls // []')

        # Display assistant text (always — may be initial thinking or final answer after tool calls)
        if [[ -n "${assistant_text}" ]]; then
            baish_output_assistant_response "${assistant_text}"
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
        baish_output_pipeline_stage "execute"
        local tc_idx
        for (( tc_idx = 0; tc_idx < tool_count; tc_idx++ )); do
            local tc
            tc=$(echo "${tool_calls}" | jq -c ".[$tc_idx]")
            local tool_id tool_name tool_args
            tool_id=$(echo "${tc}" | jq -r '.id')
            tool_name=$(echo "${tc}" | jq -r '.name')
            tool_args=$(echo "${tc}" | jq -r '.arguments')

            baish_debug_tool "${tool_name}" "id=${tool_id}"

            # Build a human-readable description from the tool arguments
            local tool_description
            tool_description=$(_baish_output_tool_description "${tool_args}")
            # Announce the tool call before execution (no newline — overwritten below)
            baish_output_tool_announce "${tool_name}" "${tool_description}"

            # Execute the tool
            local result_json
            result_json=$(baish_tool_execute "${tool_name}" "${tool_args}")

            # Append tool result to session
            baish_session_append_tool_result "${tool_id}" "${result_json}"

            # Display tool result — overwrites the announcement line
            local ok err_msg
            ok=$(echo "${result_json}" | jq -r '.ok')
            if [[ "${ok}" == "true" ]]; then
                if [[ "${tool_name}" == "bash" ]]; then
                    local bash_stdout bash_stderr bash_exit_code
                    bash_stdout=$(echo "${result_json}" | jq -r '.data.stdout // ""')
                    bash_stderr=$(echo "${result_json}" | jq -r '.data.stderr // ""')
                    bash_exit_code=$(echo "${result_json}" | jq -r '.data.exit_code // 0')
                    # Build truncation suffix for the announcement line
                    local suffix=""
                    if [[ -n "$bash_stdout" ]]; then
                        local so_lines
                        so_lines=$(printf '%s\n' "$bash_stdout" | wc -l | tr -d ' ')
                        if (( so_lines > 5 )); then
                            suffix="… $(( so_lines - 5 )) lines omitted"
                        fi
                    fi
                    if [[ -n "$bash_stderr" ]]; then
                        local se_lines
                        se_lines=$(printf '%s\n' "$bash_stderr" | wc -l | tr -d ' ')
                        if (( se_lines > 5 )); then
                            if [[ -n "$suffix" ]]; then
                                suffix+=", "
                            fi
                            suffix+="stderr … $(( se_lines - 5 )) lines omitted"
                        fi
                    fi
                    baish_output_tool_announce_ok "${tool_name}" "${tool_description}" "${suffix}"
                    baish_output_bash_output "${tool_name}" "${bash_stdout}" "${bash_stderr}" "${bash_exit_code}"
                else
                    baish_output_tool_announce_ok "${tool_name}" "${tool_description}"
                fi
            else
                err_msg=$(echo "${result_json}" | jq -r '.error.message')
                baish_output_tool_announce_error "${tool_name}" "${tool_description}" "${err_msg}"
            fi

            # Log debug summary (after ok/err_msg are set)
            if [[ "${ok}" == "true" ]]; then
                baish_debug_tool "${tool_name}" "id=${tool_id}" "success"
            else
                baish_debug_tool "${tool_name}" "id=${tool_id}" "error: ${err_msg:-unknown}"
            fi

        done

        BAISH_SESSION_TOOL_ROUNDS=$(( BAISH_SESSION_TOOL_ROUNDS + 1 ))
    done

    # Mark the pipeline as done
    baish_output_pipeline_stage "done"
    # Clean up pipeline resources
    baish_output_pipeline_cleanup

    # Clean up stderr capture file
    rm -f "${stderr_file}"
}

# Call provider chat, capturing output with a thinking spinner.
# Captures stdout (response JSON) and stderr (error signals) separately.
# Writes stderr to BAISH_CHAT_STDERR_FILE for the caller to analyze.
# Retries up to BAISH_PROVIDER_RETRY_MAX times on transient failures
# (infrastructure exit codes and GENERIC_ERROR responses) with
# BAISH_PROVIDER_RETRY_DELAY seconds between attempts.
baish_agent_provider_chat_capture() {
    local request_json="$1"

    # Extract messages and tools
    local messages tools_json
    messages=$(echo "${request_json}" | jq -c '.messages')
    tools_json=$(echo "${request_json}" | jq -c '.tools // []')

    baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "" "sending request"

    # Use a persistent temp file so stderr survives the subshell
    local stderr_file="${BAISH_CHAT_STDERR_FILE:-/tmp/baish_chat_stderr.$$}"
    local chat_fn="provider_${BAISH_CURRENT_PROVIDER}_chat"

    # ARG_MAX note: passing messages/tools between bash functions does NOT
    # go through exec, so large values are safe. The actual ARG_MAX risk is
    # inside jq --argjson calls (see session.sh and chat-parser.sh fixes).

    local max_retries="${BAISH_PROVIDER_RETRY_MAX:-5}"
    local retry_delay="${BAISH_PROVIDER_RETRY_DELAY:-1}"
    local attempt result exit_code

    # Show thinking spinner in background (only if stderr is a terminal)
    local spinner_pid=""
    if [[ -t 2 ]]; then
        baish_output_thinking_bg &
        spinner_pid=$!
    fi

    for (( attempt = 1; attempt <= max_retries; attempt++ )); do
        # Call provider chat function directly, capturing stderr to file
        result=$(${chat_fn} "${messages}" "${tools_json}" 2>"${stderr_file}")
        exit_code=$?

        # Success: exit code 0 and response is ok
        if (( exit_code == 0 )); then
            local ok error_code
            ok=$(echo "${result}" | jq -r '.ok // false')
            error_code=$(echo "${result}" | jq -r '.error.code // ""')

            if [[ "${ok}" == "true" ]]; then
                # Success — kill spinner, report, return
                if [[ -n "${spinner_pid}" ]]; then
                    kill "${spinner_pid}" 2>/dev/null
                    wait "${spinner_pid}" 2>/dev/null
                    printf "\r\033[K" >&2
                fi
                baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "200" "response received"
                echo "${result}"
                return 0
            fi

            # Only retry GENERIC_ERROR (network/transient issues).
            # Auth failures, context overflow, token expiry are permanent
            # and should propagate immediately without retry.
            if [[ "${error_code}" != "GENERIC_ERROR" ]]; then
                break
            fi

            baish_debug "Provider ${BAISH_CURRENT_PROVIDER} GENERIC_ERROR (attempt ${attempt}/${max_retries}), retrying in ${retry_delay}s..."
        else
            # Infrastructure failure (curl crash, DNS, etc.) — retryable
            baish_debug "Provider ${BAISH_CURRENT_PROVIDER} infra failure exit ${exit_code} (attempt ${attempt}/${max_retries}), retrying in ${retry_delay}s..."
        fi

        # Don't sleep after the last attempt
        if (( attempt < max_retries )); then
            sleep "${retry_delay}"
        fi
    done

    # Kill spinner and clear the line completely
    if [[ -n "${spinner_pid}" ]]; then
        kill "${spinner_pid}" 2>/dev/null
        wait "${spinner_pid}" 2>/dev/null
        printf "\r\033[K" >&2
    fi

    # All retries exhausted — propagate the last failure
    if (( exit_code != 0 )); then
        baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "${exit_code}" "error (after ${max_retries} retries)"
        return "${exit_code}"
    fi

    baish_debug_http "${BAISH_CURRENT_PROVIDER}" "POST" "chat" "0" "error response (after ${max_retries} retries)"
    echo "${result}"
    return 0
}

