#!/usr/bin/env bash
# ── lib/tui.sh — Terminal UI helpers ────────────────────────────────
# Colors, glow rendering, prompt display

# ── Colours ────────────────────────────────────────────────────────
_tui_cyan='\033[0;36m'
_tui_bold='\033[1m'
_tui_dim='\033[2m'
_tui_green='\033[0;32m'
_tui_red='\033[0;31m'
_tui_yellow='\033[0;33m'
_tui_reset='\033[0m'

# ── Print (glow-rendered if available) ─────────────────────────────
tui_print() {
    local text="$1"
    if command -v glow &>/dev/null; then
        echo "$text" | glow -s dark -w 100
    else
        echo "$text"
    fi
}

# ── Color helper ───────────────────────────────────────────────────
tui_color() {
    local code="$1" text="$2"
    printf "\033[${code}m%s\033[0m" "$text"
}

# ── Prompt ─────────────────────────────────────────────────────────
tui_prompt() {
    printf '%b' "${_tui_bold}${_tui_cyan}baish${_tui_reset} > "
}

# ── Tool execution display ─────────────────────────────────────────
tui_tool_start() {
    local tool_name="$1" args_summary="$2"
    printf '%b\n' "\r\033[K${_tui_dim}▸ ${_tui_yellow}${tool_name}${_tui_reset} ${_tui_dim}${args_summary}${_tui_reset}"
}

tui_tool_done() {
    printf '%b\n' "${_tui_dim}▸ done${_tui_reset}"
}


# ── Readline tab completion for slash commands ─────────────────────
_slash_complete() {
    local word="${READLINE_LINE:0:$READLINE_POINT}"

    # Only handle when the current word starts with / (no spaces)
    if [[ "$word" == /* && "$word" != *" "* ]]; then
        local matches=()
        for cmd in "${!_SLASH_COMMANDS[@]}"; do
            if [[ "$cmd" == "$word"* ]]; then
                matches+=("$cmd")
            fi
        done

        if [[ ${#matches[@]} -eq 1 ]]; then
            # Single match: complete it
            READLINE_LINE="${matches[0]}${READLINE_LINE:$READLINE_POINT}"
            READLINE_POINT=${#matches[0]}
        elif [[ ${#matches[@]} -gt 1 ]]; then
            # Multiple matches: display above current line
            echo ""
            for cmd in $(printf '%s\n' "${matches[@]}" | sort); do
                local desc="${_SLASH_COMMANDS[$cmd]:-}"
                if [[ -n "$desc" ]]; then
                    echo -e "  ${_tui_cyan}${cmd}${_tui_reset}  ${_tui_dim}${desc}${_tui_reset}"
                else
                    echo -e "  ${_tui_cyan}${cmd}${_tui_reset}"
                fi
            done
        fi
    fi
}

# ── Setup readline tab completion (call before agent_loop) ─────────
tui_setup_readline() {
    bind -x '"\t": _slash_complete'
}
