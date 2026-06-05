#!/usr/bin/env bash
# BAISH — Mock provider for testing
# selectable: false — used only for bats tests and development

# Pre-programmed responses for testing (set by tests or debug use)
# BAISH_MOCK_RESPONSE: fixed assistant response text
# BAISH_MOCK_TOOL_CALLS: JSON array of pre-programmed tool calls
# BAISH_MOCK_EXIT_CODE: force a non-zero exit code for infrastructure failure (default: 0)
# BAISH_MOCK_ERROR_CODE: error code for structured error response (TOKEN_EXPIRED, AUTH_FAILURE, CONTEXT_OVERFLOW)
#   When set, mock returns {"ok": false, "error": {"code": "...", "message": "..."}} on stdout instead of failing
BAISH_MOCK_RESPONSE="${BAISH_MOCK_RESPONSE:-I am the mock provider. Your message was received.}"
BAISH_MOCK_TOOL_CALLS="${BAISH_MOCK_TOOL_CALLS:-}"
BAISH_MOCK_EXIT_CODE="${BAISH_MOCK_EXIT_CODE:-0}"
BAISH_MOCK_ERROR_CODE="${BAISH_MOCK_ERROR_CODE:-}"

provider_mock_metadata() {
    jq -n \
        '{"id": "mock", "label": "Mock Provider", "desc": "Mock LLM provider for testing. Returns fixed responses.", "selectable": false}'
}

provider_mock_auth() {
    # No-op: mock provider never needs authentication
    return 0
}

provider_mock_list_models() {
    jq -n '[{"id": "mock-model", "name": "Mock Model"}]'
}

provider_mock_chat() {
    # Args: messages_json tools_json
    local messages_json="$1"
    local tools_json="$2"

    # Infrastructure failure (curl crash, etc.) — exit code only
    if [[ "${BAISH_MOCK_EXIT_CODE}" != "0" ]]; then
        return "${BAISH_MOCK_EXIT_CODE}"
    fi

    # Structured error simulation (provider-level error on stdout)
    if [[ -n "${BAISH_MOCK_ERROR_CODE}" ]]; then
        jq -n \
            --arg code "${BAISH_MOCK_ERROR_CODE}" \
            '{"ok": false, "error": {"code": $code, "message": "mock error simulation"}}'
        return 0
    fi

    local assistant_text tool_calls
    assistant_text="${BAISH_MOCK_RESPONSE}"

    if [[ -n "${BAISH_MOCK_TOOL_CALLS}" ]]; then
        tool_calls="${BAISH_MOCK_TOOL_CALLS}"
    else
        tool_calls="[]"
    fi

    jq -n --arg text "${assistant_text}" --argjson tc "${tool_calls}" \
        '{"ok": true, "assistant_text": $text, "tool_calls": $tc}'
}

provider_mock_has_env_auth() {
    # Mock always "has auth"
    return 0
}
