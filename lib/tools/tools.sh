#!/usr/bin/env bash
# BAISH — Tool stubs (to be implemented in later slices)
# These are stubs so the tool engine can dispatch without errors

source "${BASH_SOURCE%/*}/engine.sh"

baish_tool_read() {
    local args_json="$1"
    baish_tool_error_json "read" "NOT_IMPLEMENTED" "Read tool not yet implemented"
}

baish_tool_write() {
    local args_json="$1"
    baish_tool_error_json "write" "NOT_IMPLEMENTED" "Write tool not yet implemented"
}

baish_tool_edit() {
    local args_json="$1"
    baish_tool_error_json "edit" "NOT_IMPLEMENTED" "Edit tool not yet implemented"
}

baish_tool_bash() {
    local args_json="$1"
    baish_tool_error_json "bash" "NOT_IMPLEMENTED" "Bash tool not yet implemented"
}
