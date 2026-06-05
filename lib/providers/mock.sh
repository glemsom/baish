#!/usr/bin/env bash
# BAISH — Mock provider for testing
# selectable: false — used only for bats tests and development

# Pre-programmed responses for testing (set by tests or debug use)
# BAISH_MOCK_RESPONSE: fixed assistant response text
# BAISH_MOCK_TOOL_CALLS: JSON array of pre-programmed tool calls
# BAISH_MOCK_EXIT_CODE: force a non-zero exit code (default: 0)
# BAISH_MOCK_STDERR: content to write to stderr (for error simulation)
BAISH_MOCK_RESPONSE="${BAISH_MOCK_RESPONSE:-I am the mock provider. Your message was received.}"
BAISH_MOCK_TOOL_CALLS="${BAISH_MOCK_TOOL_CALLS:-}"
BAISH_MOCK_EXIT_CODE="${BAISH_MOCK_EXIT_CODE:-0}"
BAISH_MOCK_STDERR="${BAISH_MOCK_STDERR:-}"

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

    # Simulate error scenarios for testing
    if [[ "${BAISH_MOCK_EXIT_CODE}" != "0" ]]; then
        if [[ -n "${BAISH_MOCK_STDERR}" ]]; then
            echo "${BAISH_MOCK_STDERR}" >&2
        fi
        return "${BAISH_MOCK_EXIT_CODE}"
    fi

    local assistant_text tool_calls
    assistant_text="${BAISH_MOCK_RESPONSE}"

    if [[ -n "${BAISH_MOCK_TOOL_CALLS}" ]]; then
        tool_calls="${BAISH_MOCK_TOOL_CALLS}"
    else
        tool_calls="[]"
    fi

    jq -n --arg text "${assistant_text}" --argjson tc "${tool_calls}" \
        '{"assistant_text": $text, "tool_calls": $tc}'
}

provider_mock_has_env_auth() {
    # Mock always "has auth"
    return 0
}
