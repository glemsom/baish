#!/usr/bin/env bash
# BAISH — Error handling and resilience layer
#
# Centralized error handling for provider errors.
# Providers return structured JSON on stdout:
#   {"ok": true, "assistant_text": "...", "tool_calls": [...]}
#   {"ok": false, "error": {"code": "...", "message": "..."}}
#
# Error codes: CONTEXT_OVERFLOW, TOKEN_EXPIRED, AUTH_FAILURE, GENERIC_ERROR
#
#   - CONTEXT_OVERFLOW → show guidance to use /new, exit gracefully
#   - AUTH_FAILURE     → loud error message, require user to re-authenticate
#   - GENERIC_ERROR    → print error details, exit loop

# Error type constants
BAISH_ERR_CONTEXT_OVERFLOW="CONTEXT_OVERFLOW"
BAISH_ERR_TOKEN_EXPIRED="TOKEN_EXPIRED"
BAISH_ERR_AUTH_FAILURE="AUTH_FAILURE"
BAISH_ERR_GENERIC="GENERIC_ERROR"

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
# Args: error_json ({"code": "...", "message": "..."}), provider_id
# Returns 0 to continue, 1 to break the loop.
baish_handle_provider_error() {
    local error_json="$1"
    local provider_id="$2"

    local error_code error_message
    error_code=$(echo "${error_json}" | jq -r '.code // "GENERIC_ERROR"')
    error_message=$(echo "${error_json}" | jq -r '.message // ""')

    baish_debug "Provider error detected: type=${error_code}, provider=${provider_id}"

    case "${error_code}" in
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
            baish_print_auth_failure "${provider_id}" "${error_message:-Your credentials are invalid or have been revoked.}"
            return 1
            ;;
        *)
            # Generic error — print the error message
            if [[ -n "${error_message}" ]]; then
                baish_print_error "Provider error (${provider_id}): ${error_message}"
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
