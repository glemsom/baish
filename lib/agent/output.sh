#!/usr/bin/env bash
# BAISH — User Output module
# Single deep module for all user-facing terminal output.
# Color codes and icons are internal — callers never reach for raw escape codes or icon variables.

source "${BASH_SOURCE%/*}/config.sh"

# ============================================================================
# Internal: ANSI color codes and Unicode icons
# ============================================================================

_BAISH_COLOR_RESET='\033[0m'
_BAISH_COLOR_BOLD='\033[1m'
_BAISH_COLOR_DIM='\033[2m'
_BAISH_COLOR_RED='\033[31m'
_BAISH_COLOR_GREEN='\033[32m'
_BAISH_COLOR_YELLOW='\033[33m'
_BAISH_COLOR_BLUE='\033[34m'
_BAISH_COLOR_CYAN='\033[36m'

_BAISH_ICON_READ='📖'
_BAISH_ICON_WRITE='📝'
_BAISH_ICON_EDIT='✏️'
_BAISH_ICON_BASH='⚙️'
_BAISH_ICON_ERROR='❌'
_BAISH_ICON_DEFAULT='🔧'

# Resolve a tool icon from the tool name.
_baish_output_tool_icon() {
    local tool_name="$1"
    case "${tool_name}" in
        read)    printf '%s' "${_BAISH_ICON_READ}" ;;
        write)   printf '%s' "${_BAISH_ICON_WRITE}" ;;
        edit)    printf '%s' "${_BAISH_ICON_EDIT}" ;;
        bash)    printf '%s' "${_BAISH_ICON_BASH}" ;;
        *)       printf '%s' "${_BAISH_ICON_DEFAULT}" ;;
    esac
}

# ============================================================================
# Banner and prompt
# ============================================================================

baish_output_banner() {
    printf "\n${_BAISH_COLOR_BOLD}${_BAISH_COLOR_CYAN}"
    printf "  ╔══════════════════════════════════════════╗\n"
    printf "  ║  BAISH — Bash AI Shell                   ║\n"
    printf "  ║  Type a message or /help for commands    ║\n"
    printf "  ╚══════════════════════════════════════════╝\n"
    printf "${_BAISH_COLOR_RESET}\n"
}

baish_output_prompt() {
    local provider="$1"
    local model="$2"
    printf "${_BAISH_COLOR_GREEN}[%s/%s]${_BAISH_COLOR_RESET} > " "${provider}" "${model}"
}

# ============================================================================
# Assistant response
# ============================================================================

baish_output_assistant_response() {
    local text="$1"
    printf "\n${_BAISH_COLOR_BOLD}BAISH:${_BAISH_COLOR_RESET}\n"
    if command -v gum &>/dev/null; then
        echo "${text}" | gum format --theme=dracula
    else
        echo "${text}"
    fi
    printf "\n"
}

# ============================================================================
# Tool result display
# ============================================================================

# Display a tool result summary. Icon is resolved from tool name internally.
# Args: tool_name, summary
baish_output_tool_result() {
    local tool_name="$1"
    local summary="$2"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    printf "${_BAISH_COLOR_DIM}  %s %s${_BAISH_COLOR_RESET}\n" "${icon}" "${summary}"
}

# Display a tool error summary with error icon.
# Args: tool_name, error_summary
baish_output_tool_error() {
    local tool_name="$1"
    local error_summary="$2"
    printf "${_BAISH_COLOR_DIM}  %s %s: %s${_BAISH_COLOR_RESET}\n" "${_BAISH_ICON_ERROR}" "${tool_name}" "${error_summary}"
}

# Display bash tool output with colored formatting.
# Icon is resolved from tool name internally.
# Args: tool_name, stdout, stderr, exit_code
baish_output_bash_output() {
    local tool_name="$1"
    local stdout_content="$2"
    local stderr_content="$3"
    local exit_code="$4"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")

    if [[ -n "$stdout_content" ]]; then
        printf "${_BAISH_COLOR_DIM}  %s stdout:${_BAISH_COLOR_RESET}\n" "${icon}"
        printf "${_BAISH_COLOR_GREEN}%s${_BAISH_COLOR_RESET}\n" "$stdout_content"
    fi

    if [[ -n "$stderr_content" ]]; then
        printf "${_BAISH_COLOR_DIM}  %s stderr:${_BAISH_COLOR_RESET}\n" "${icon}"
        printf "${_BAISH_COLOR_RED}%s${_BAISH_COLOR_RESET}\n" "$stderr_content"
    fi

    if (( exit_code != 0 )); then
        printf "${_BAISH_COLOR_YELLOW}  %s exit code: %s${_BAISH_COLOR_RESET}\n" "${icon}" "$exit_code"
    fi
}

# ============================================================================
# Extract a human-readable description from tool arguments JSON.
# read/write/edit → path field, bash → command field, fallback → "?"
# Descriptions over 100 characters are truncated with … suffix.
_baish_output_tool_description() {
    local tool_args="$1"
    local desc
    desc=$(echo "${tool_args}" | jq -r '.path // .command // "?"')
    if (( ${#desc} > 100 )); then
        desc="${desc:0:99}…"
    fi
    printf '%s' "${desc}"
}

# Tool announcement and result (replace-in-place)
# ============================================================================

# Announce a tool call before it executes (no trailing newline, uses \r so the
# line can be overwritten by the success/error update).
# Args: tool_name, description (path, command, etc.)
baish_output_tool_announce() {
    local tool_name="$1"
    local description="$2"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    printf "\r${_BAISH_COLOR_DIM}  🔄 %s %s${_BAISH_COLOR_RESET}" "${icon}" "${description}"
}

# Update a tool announcement on success — overwrites the "🔄" line.
# Args: tool_name, description
baish_output_tool_announce_ok() {
    local tool_name="$1"
    local description="$2"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    printf "\r\033[K  ✅ %s %s${_BAISH_COLOR_RESET}\n" "${icon}" "${description}"
}

# Update a tool announcement on error — overwrites the "🔄" line.
# Args: tool_name, description, error_message
baish_output_tool_announce_error() {
    local tool_name="$1"
    local description="$2"
    local error_msg="$3"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    printf "\r\033[K  ❌ %s %s — %s${_BAISH_COLOR_RESET}\n" "${icon}" "${description}" "${error_msg}"
}

# ============================================================================
# Info and error messages
# ============================================================================

baish_output_error() {
    printf "${_BAISH_COLOR_RED}Error: %s${_BAISH_COLOR_RESET}\n" "$1" >&2
}

baish_output_info() {
    printf "${_BAISH_COLOR_BLUE}%s${_BAISH_COLOR_RESET}\n" "$1"
}

# ============================================================================
# Thinking spinner (foreground and background)
# ============================================================================

# Foreground spinner: takes a PID and shows spinner while the process is alive.
baish_output_thinking() {
    local pid="$1"
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${_BAISH_COLOR_CYAN}  %s thinking...${_BAISH_COLOR_RESET}" "${chars[$i]}"
        i=$(( (i + 1) % ${#chars[@]} ))
        sleep 0.1
    done
    printf "\r                             \r"
}

# Background spinner: runs forever, printing to stderr so it doesn't pollute stdout.
# Should be launched as a background job: baish_output_thinking_bg &
baish_output_thinking_bg() {
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
        printf "\r${_BAISH_COLOR_CYAN}  %s thinking...${_BAISH_COLOR_RESET}" "${chars[$i]}" >&2
        i=$(( (i + 1) % ${#chars[@]} ))
        sleep 0.1
    done
}

# ============================================================================
# Error guidance messages
# ============================================================================

# Print user-facing guidance when context overflow is detected.
baish_output_context_overflow_help() {
    baish_output_info ""
    baish_output_info "⚠️  Context window exceeded — the conversation is too long for the model."
    baish_output_info ""
    baish_output_info "  Use ${_BAISH_COLOR_BOLD}/new${_BAISH_COLOR_RESET} to clear conversation history and continue."
    baish_output_info ""
    baish_debug "Context overflow detected — user advised to use /new"
}

# Print a loud, actionable auth failure message.
# Args: provider_id, optional detail message
baish_output_auth_failure() {
    local provider_id="$1"
    local detail="${2:-}"

    baish_output_error ""
    baish_output_error "❌ Authentication failed for ${provider_id}!"
    baish_output_error ""
    if [[ -n "${detail}" ]]; then
        baish_output_error "  ${detail}"
        baish_output_error ""
    fi
    baish_output_error "  Please fix your credentials and run ${_BAISH_COLOR_BOLD}/connect${_BAISH_COLOR_RESET} to re-authenticate."
    baish_output_error ""
    baish_debug "Auth failure for provider: ${provider_id}${detail:+ — ${detail}}"
}
