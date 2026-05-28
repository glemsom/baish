#!/usr/bin/env bash
# ── lib/tui.sh — Terminal UI helpers ────────────────────────────────
# Spinner, colors, glow rendering, prompt display

# ── Colours ────────────────────────────────────────────────────────
_tui_cyan='\033[0;36m'
_tui_bold='\033[1m'
_tui_dim='\033[2m'
_tui_green='\033[0;32m'
_tui_red='\033[0;31m'
_tui_yellow='\033[0;33m'
_tui_reset='\033[0m'

# ── Spinner state ──────────────────────────────────────────────────
_tui_spinner_pid=""
_tui_spinner_msg=""

# ── Spinner implementation (pure bash, background subshell) ────────
_tui_spinner_run() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
        printf "\r${_tui_cyan}%s${_tui_reset}  %s" "${frames[i]}" "$msg"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done
}

tui_spinner_start() {
    _tui_spinner_msg="$1"
    _tui_spinner_run "$_tui_spinner_msg" &
    _tui_spinner_pid=$!
    # Disable cursor
    printf '\033[?25l'
}

tui_spinner_stop() {
    if [[ -n "$_tui_spinner_pid" ]] && kill -0 "$_tui_spinner_pid" 2>/dev/null; then
        kill "$_tui_spinner_pid" 2>/dev/null || true
        wait "$_tui_spinner_pid" 2>/dev/null || true
        _tui_spinner_pid=""
    fi
    # Re-enable cursor, clear spinner line
    printf '\033[?25h\r\033[K'
}

tui_spinner_update() {
    _tui_spinner_msg="$1"
    # Restart spinner with new message
    if [[ -n "$_tui_spinner_pid" ]] && kill -0 "$_tui_spinner_pid" 2>/dev/null; then
        kill "$_tui_spinner_pid" 2>/dev/null || true
        wait "$_tui_spinner_pid" 2>/dev/null || true
    fi
    _tui_spinner_run "$_tui_spinner_msg" &
    _tui_spinner_pid=$!
}

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

# ── Interrupt handler (stops spinner gracefully) ───────────────────
_tui_interrupt_handler() {
    tui_spinner_stop
    printf "\r\033[K"
    tui_prompt
}
