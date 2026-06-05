#!/usr/bin/env bash
# BAISH — Shared Provider Chat Response Parser
# Parses HTTP responses from LLM provider chat APIs.
# Handles error detection (context overflow, auth failure, generic errors)
# and normalizes successful Chat Completions responses.

# Parse an HTTP error response from a provider chat API.
# Detects context overflow, auth failures, and generic errors.
# Args:
#   http_code        - HTTP status code
#   body             - response body (JSON string)
#   error_msg_jq     - jq filter to extract error message (e.g., '.error.message // .message')
#   auth_error_code  - error code for 401/403 responses (e.g., "TOKEN_EXPIRED", "AUTH_FAILURE")
#   provider_prefix  - optional prefix for generic error messages (e.g., "Kilo: ")
# Returns:
#   Error JSON on stdout if an error was detected; empty string for HTTP 200.
#   Always returns exit code 0.
baish_provider_parse_error_body() {
    local http_code="$1"
    local body="$2"
    local error_msg_jq="$3"
    local auth_error_code="$4"
    local provider_prefix="${5:-}"

    # HTTP 200 — no error
    if [[ "${http_code}" == "200" ]]; then
        return 0
    fi

    # Extract error message using the provided jq filter
    local error_msg
    error_msg=$(echo "${body}" | jq -r "${error_msg_jq} // \"Unknown error\"" 2>/dev/null)

    # Context overflow detection
    if echo "${body}" | grep -qi "context_length_exceeded\|context.*exceeded\|too long"; then
        jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "CONTEXT_OVERFLOW", "message": $msg}}'
        return 0
    fi

    # Auth failure (401 or 403)
    if [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
        jq -n --arg code "${auth_error_code}" --arg msg "${error_msg}" \
            '{"ok": false, "error": {"code": $code, "message": $msg}}'
        return 0
    fi

    # Generic error — include HTTP status and provider prefix
    local generic_msg="${provider_prefix}Chat error (HTTP ${http_code}): ${error_msg}"
    jq -n --arg msg "${generic_msg}" '{"ok": false, "error": {"code": "GENERIC_ERROR", "message": $msg}}'
    return 0
}

# Build an OpenAI-compatible Chat Completions payload.
# Args: model, messages_json, tools_json
# Returns JSON payload string on stdout.
# Omits tools key when tools_json is empty, null, or "[]".
baish_provider_build_chat_payload() {
    local model="$1"
    local messages_json="$2"
    local tools_json="$3"

    if [[ -n "${tools_json}" && "${tools_json}" != "[]" && "${tools_json}" != "null" ]]; then
        jq -n \
            --arg model "${model}" \
            --argjson messages "${messages_json}" \
            --argjson tools "${tools_json}" \
            '{
                "model": $model,
                "messages": $messages,
                "tools": $tools,
                "stream": false,
                "parallel_tool_calls": false
            }'
    else
        jq -n \
            --arg model "${model}" \
            --argjson messages "${messages_json}" \
            '{
                "model": $model,
                "messages": $messages,
                "stream": false
            }'
    fi
}

# Parse a successful Chat Completions API response body.
# Extracts assistant_text and normalizes tool_calls from OpenAI format
# ({id, type, function: {name, arguments}}) to internal format ({id, name, arguments}).
# Args: body (JSON response body from a Chat Completions API)
# Returns: {"ok": true, "assistant_text": "...", "tool_calls": [...]} on stdout
baish_provider_parse_chat_response_body() {
    local body="$1"

    local assistant_text
    assistant_text=$(echo "${body}" | jq -r '.choices[0].message.content // ""')

    local tool_calls
    tool_calls=$(echo "${body}" | jq -c '
        .choices[0].message.tool_calls // [] |
        [.[] | {
            "id": .id,
            "name": .function.name,
            "arguments": .function.arguments
        }]
    ')

    jq -n \
        --arg text "${assistant_text}" \
        --argjson tc "${tool_calls}" \
        '{"ok": true, "assistant_text": $text, "tool_calls": $tc}'
}
