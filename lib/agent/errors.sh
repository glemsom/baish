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

source "${BASH_SOURCE%/*}/output.sh"

# Error type constants
BAISH_ERR_CONTEXT_OVERFLOW="CONTEXT_OVERFLOW"
BAISH_ERR_TOKEN_EXPIRED="TOKEN_EXPIRED"
BAISH_ERR_AUTH_FAILURE="AUTH_FAILURE"
BAISH_ERR_GENERIC="GENERIC_ERROR"

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
            baish_output_context_overflow_help
            return 1
            ;;
        "${BAISH_ERR_TOKEN_EXPIRED}")
            # Token expiry should have been handled by the provider's auto-reconnect.
            # If we get here, auto-reconnect also failed — treat as auth failure.
            baish_output_auth_failure "${provider_id}" "Token refresh failed. Your session may have expired."
            return 1
            ;;
        "${BAISH_ERR_AUTH_FAILURE}")
            baish_output_auth_failure "${provider_id}" "${error_message:-Your credentials are invalid or have been revoked.}"
            return 1
            ;;
        *)
            # Generic error — print the error message
            if [[ -n "${error_message}" ]]; then
                baish_output_error "Provider error (${provider_id}): ${error_message}"
            else
                baish_output_error "Provider ${provider_id} returned an error (no details)"
            fi
            return 1
            ;;
    esac
}
