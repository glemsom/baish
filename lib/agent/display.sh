#!/usr/bin/env bash
# BAISH — Display and UI helpers

source "${BASH_SOURCE%/*}/config.sh"

baish_print_banner() {
    printf "\n${BAISH_COLOR_BOLD}${BAISH_COLOR_CYAN}"
    printf "  ╔══════════════════════════════════════════╗\n"
    printf "  ║  BAISH — Bash AI Shell                   ║\n"
    printf "  ║  Type a message or /help for commands    ║\n"
    printf "  ╚══════════════════════════════════════════╝\n"
    printf "${BAISH_COLOR_RESET}\n"
}

baish_print_thinking() {
    local pid="$1"
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BAISH_COLOR_CYAN}  %s thinking...${BAISH_COLOR_RESET}" "${chars[$i]}"
        i=$(( (i + 1) % ${#chars[@]} ))
        sleep 0.1
    done
    printf "\r                             \r"
}

baish_print_assistant_response() {
    local text="$1"
    printf "\n${BAISH_COLOR_BOLD}BAISH:${BAISH_COLOR_RESET}\n"
    if command -v gum &>/dev/null; then
        echo "${text}" | gum format
    else
        echo "${text}"
    fi
    printf "\n"
}

baish_print_tool_result() {
    local icon="$1"
    local summary="$2"
    printf "${BAISH_COLOR_DIM}  %s %s${BAISH_COLOR_RESET}\n" "${icon}" "${summary}"
}

# Display bash tool output with colored formatting
# Args: icon, stdout, stderr, exit_code
baish_print_bash_output() {
    local icon="$1"
    local stdout_content="$2"
    local stderr_content="$3"
    local exit_code="$4"

    if [[ -n "$stdout_content" ]]; then
        printf "${BAISH_COLOR_DIM}  %s stdout:${BAISH_COLOR_RESET}\n" "${icon}"
        printf "${BAISH_COLOR_GREEN}%s${BAISH_COLOR_RESET}\n" "$stdout_content"
    fi

    if [[ -n "$stderr_content" ]]; then
        printf "${BAISH_COLOR_DIM}  %s stderr:${BAISH_COLOR_RESET}\n" "${icon}"
        printf "${BAISH_COLOR_RED}%s${BAISH_COLOR_RESET}\n" "$stderr_content"
    fi

    if (( exit_code != 0 )); then
        printf "${BAISH_COLOR_YELLOW}  %s exit code: %s${BAISH_COLOR_RESET}\n" "${icon}" "$exit_code"
    fi
}

baish_print_error() {
    printf "${BAISH_COLOR_RED}Error: %s${BAISH_COLOR_RESET}\n" "$1" >&2
}

baish_print_info() {
    printf "${BAISH_COLOR_BLUE}%s${BAISH_COLOR_RESET}\n" "$1"
}

baish_print_prompt() {
    local provider="$1"
    local model="$2"
    printf "${BAISH_COLOR_GREEN}[%s/%s]${BAISH_COLOR_RESET} > " "${provider}" "${model}"
}
