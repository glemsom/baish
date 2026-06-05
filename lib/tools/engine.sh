#!/usr/bin/env bash
# BAISH — Tool execution engine
# Executes tool calls and returns standardized JSON results

source "${BASH_SOURCE%/*}/../agent/config.sh"

# Tool result helpers
baish_tool_success_json() {
    local tool_name="$1"
    local data_json="$2"
    jq -n --arg tool "${tool_name}" --argjson data "${data_json}" \
        '{"ok": true, "tool": $tool, "data": $data}'
}

baish_tool_error_json() {
    local tool_name="$1"
    local code="$2"
    local message="$3"
    jq -n --arg tool "${tool_name}" --arg code "${code}" --arg message "${message}" \
        '{"ok": false, "tool": $tool, "error": {"code": $code, "message": $message}}'
}

# Main tool dispatcher
baish_tool_execute() {
    local tool_name="$1"
    local args_json="$2"

    case "${tool_name}" in
        read)
            baish_tool_read "${args_json}"
            ;;
        write)
            baish_tool_write "${args_json}"
            ;;
        edit)
            baish_tool_edit "${args_json}"
            ;;
        bash)
            baish_tool_bash "${args_json}"
            ;;
        *)
            baish_tool_error_json "${tool_name}" "UNKNOWN_TOOL" "Unknown tool: ${tool_name}"
            ;;
    esac
}
