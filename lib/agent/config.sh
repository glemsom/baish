#!/usr/bin/env bash
# BAISH — Configuration and defaults

# Maximum number of tool call rounds per user message
BAISH_MAX_TOOL_ROUNDS="${BAISH_MAX_TOOL_ROUNDS:-20}"

# Maximum total tool calls across the session
BAISH_MAX_TOOL_CALLS="${BAISH_MAX_TOOL_CALLS:-100}"

# Bash command execution timeout in seconds
BAISH_BASH_TIMEOUT="${BAISH_BASH_TIMEOUT:-120}"

# Debug logging flag
BAISH_DEBUG="${BAISH_DEBUG:-0}"

# Debug logging
baish_debug() {
    if [[ "$BAISH_DEBUG" == "1" ]]; then
        printf '\033[2m[DEBUG] %s\033[0m\n' "$*" >&2
    fi
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
