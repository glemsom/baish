#!/usr/bin/env bash
# BAISH — Error handling and resilience layer
#
# Centralized error detection, classification, and handling for provider errors.
# Error types: CONTEXT_OVERFLOW, TOKEN_EXPIRED, AUTH_FAILURE, GENERIC_ERROR
#
# Provider stderr patterns are analyzed to classify errors. The run-loop uses
# these classifications to respond appropriately:
#   - CONTEXT_OVERFLOW → show guidance to use /new, exit gracefully
#   - AUTH_FAILURE     → loud error message, require user to re-authenticate
#   - GENERIC_ERROR    → print error details, exit loop

# Error type constants
BAISH_ERR_CONTEXT_OVERFLOW="CONTEXT_OVERFLOW"
BAISH_ERR_TOKEN_EXPIRED="TOKEN_EXPIRED"
BAISH_ERR_AUTH_FAILURE="AUTH_FAILURE"
BAISH_ERR_GENERIC="GENERIC_ERROR"

# Detect the type of error from provider stderr output.
# Args: stderr_content
# Prints the error type to stdout. Returns 0 always.
baish_detect_error_type() {
    local stderr_content="$1"

    # Check for context overflow patterns
    if echo "${stderr_content}" | grep -qi "context_length_exceeded\|context.*exceeded\|too long\|CONTEXT_OVERFLOW"; then
        echo "${BAISH_ERR_CONTEXT_OVERFLOW}"
        return 0
    fi

    # Check for explicit token expiry signal (must be before generic auth checks)
    if echo "${stderr_content}" | grep -qi "TOKEN_EXPIRED\|token.*expir"; then
        echo "${BAISH_ERR_TOKEN_EXPIRED}"
        return 0
    fi

    # Check for auth failure patterns
    if echo "${stderr_content}" | grep -qi "AUTH_FAILURE\|invalid.*credential\|invalid.*key\|bad.*key\|OAuth.*denied\|denied.*OAuth\|401\|403"; then
        echo "${BAISH_ERR_AUTH_FAILURE}"
        return 0
    fi

    echo "${BAISH_ERR_GENERIC}"
    return 0
}

# Print user-facing guidance when context overflow is detected.
baish_print_context_overflow_help() {
    baish_print_info ""
    baish_print_info "⚠️  Context window exceeded — the conversation is too long for the model."
    baish_print_info ""
    baish_print_info "  Use ${BAISH_COLOR_BOLD}/new${BAISH_COLOR_RESET} to clear conversation history and continue."
    baish_print_info ""
    baish_debug "Context overflow detected — user advised to use /new"
}

# Print a loud, actionable auth failure message.
# Args: provider_id, optional detail message
baish_print_auth_failure() {
    local provider_id="$1"
    local detail="${2:-}"

    baish_print_error ""
    baish_print_error "❌ Authentication failed for ${provider_id}!"
    baish_print_error ""
    if [[ -n "${detail}" ]]; then
        baish_print_error "  ${detail}"
        baish_print_error ""
    fi
    baish_print_error "  Please fix your credentials and run ${BAISH_COLOR_BOLD}/connect${BAISH_COLOR_RESET} to re-authenticate."
    baish_print_error ""
    baish_debug "Auth failure for provider: ${provider_id}${detail:+ — ${detail}}"
}

# Handle a provider error in the agent run-loop.
# Classifies the error and takes appropriate action.
# Args: stderr_content, provider_id
# Returns 0 to continue, 1 to break the loop.
baish_handle_provider_error() {
    local stderr_content="$1"
    local provider_id="$2"

    local error_type
    error_type=$(baish_detect_error_type "${stderr_content}")

    baish_debug "Provider error detected: type=${error_type}, provider=${provider_id}"

    case "${error_type}" in
        "${BAISH_ERR_CONTEXT_OVERFLOW}")
            baish_print_context_overflow_help
            return 1
            ;;
        "${BAISH_ERR_TOKEN_EXPIRED}")
            # Token expiry should have been handled by the provider's auto-reconnect.
            # If we get here, auto-reconnect also failed — treat as auth failure.
            baish_print_auth_failure "${provider_id}" "Token refresh failed. Your session may have expired."
            return 1
            ;;
        "${BAISH_ERR_AUTH_FAILURE}")
            baish_print_auth_failure "${provider_id}" "Your credentials are invalid or have been revoked."
            return 1
            ;;
        *)
            # Generic error — print whatever the provider sent
            if [[ -n "${stderr_content}" ]]; then
                baish_print_error "Provider error (${provider_id}): ${stderr_content}"
            else
                baish_print_error "Provider ${provider_id} returned an error (no details)"
            fi
            return 1
            ;;
    esac
}

# Log a debug message with structured context for HTTP requests.
# Args: provider_id, method, url, status_code (optional), detail (optional)
baish_debug_http() {
    local provider_id="$1"
    local method="$2"
    local url="$3"
    local status="${4:-}"
    local detail="${5:-}"

    if [[ "$BAISH_DEBUG" == "1" ]]; then
        local msg="HTTP ${method} ${url}"
        if [[ -n "${status}" ]]; then
            msg+=" → ${status}"
        fi
        if [[ -n "${detail}" ]]; then
            msg+=" (${detail})"
        fi
        baish_debug "[${provider_id}] ${msg}"
    fi
}

# Log a debug message for tool execution.
# Args: tool_name, tool_args_json (optional), result_summary (optional)
baish_debug_tool() {
    local tool_name="$1"
    local args_summary="${2:-}"
    local result_summary="${3:-}"

    if [[ "$BAISH_DEBUG" == "1" ]]; then
        local msg="Tool: ${tool_name}"
        if [[ -n "${args_summary}" ]]; then
            msg+=" args=(${args_summary})"
        fi
        if [[ -n "${result_summary}" ]]; then
            msg+=" → ${result_summary}"
        fi
        baish_debug "${msg}"
    fi
}

# Log a debug message for state transitions.
# Args: from_state, to_state, detail (optional)
baish_debug_state() {
    local from_state="$1"
    local to_state="$2"
    local detail="${3:-}"

    if [[ "$BAISH_DEBUG" == "1" ]]; then
        local msg="State: ${from_state} → ${to_state}"
        if [[ -n "${detail}" ]]; then
            msg+=" (${detail})"
        fi
        baish_debug "${msg}"
    fi
}
