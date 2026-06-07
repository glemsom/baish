#!/usr/bin/env bash
# BAISH — User Output module
# Single deep module for all user-facing terminal output.
# Color codes and icons are internal — callers never reach for raw escape codes or icon variables.
source "${BASH_SOURCE%/*}/config.sh"

# Internal: ANSI color codes and Unicode icons
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

# Banner and prompt
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

# Build a readline-safe prompt string for use with 'read -e -p'.
# Wraps ANSI escape sequences in \001 / \002 so readline properly
# calculates the prompt width for redraws (TAB completion, etc.).
# Without this, readline draws from column 0 and overwrites the
# separately-printed prompt.
baish_output_readline_prompt() {
    local provider="$1"
    local model="$2"
    # \001 = start of non-printing chars, \002 = end (readline RL_PROMPT_START_IGNORE/RL_PROMPT_END_IGNORE)
    printf '\001\033[32m\002[%s/%s]\001\033[0m\002 > ' "${provider}" "${model}"
}

# Assistant response
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

# Tool result display
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
# Only the last 5 lines of stdout/stderr are shown to avoid filling the chat window.
# Args: tool_name, stdout, stderr, exit_code
baish_output_bash_output() {
    local tool_name="$1"
    local stdout_content="$2"
    local stderr_content="$3"
    local exit_code="$4"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    if [[ -n "$stdout_content" ]]; then
        local stdout_indented
        stdout_indented=$(printf '%s\n' "$stdout_content" | sed 's/^/    /')
        printf "${_BAISH_COLOR_GREEN}%s${_BAISH_COLOR_RESET}\n" "$stdout_indented"
    fi
    if [[ -n "$stderr_content" ]]; then
        local stderr_indented
        stderr_indented=$(printf '%s\n' "$stderr_content" | sed 's/^/    /')
        printf "${_BAISH_COLOR_RED}%s${_BAISH_COLOR_RESET}\n" "$stderr_indented"
    fi
    if (( exit_code != 0 )); then
        printf "${_BAISH_COLOR_YELLOW}  %s exit code: %s${_BAISH_COLOR_RESET}\n" "${icon}" "$exit_code"
    fi
}

# Extract a human-readable description from tool arguments JSON.
# read/write/edit → path field, bash → cmd field, fallback → "?"
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
# Announce a tool call before it executes (no trailing newline, uses \r so the
# line can be overwritten by the success/error update).
# Args: tool_name, desc (path, cmd, etc.)
baish_output_tool_announce() {
    local tool_name="$1"
    local desc="$2"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    printf "\r${_BAISH_COLOR_DIM}  🔄 %s %s${_BAISH_COLOR_RESET}" "${icon}" "${desc}"
}

# Update a tool announcement on success — overwrites the "🔄" line.
# Args: tool_name, desc
baish_output_tool_announce_ok() {
    local tool_name="$1"
    local desc="$2"
    local suffix="${3:-}"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    if [[ -n "$suffix" ]]; then
        printf "\r\033[K  ✅ %s %s  ${_BAISH_COLOR_DIM}%s${_BAISH_COLOR_RESET}\n" "${icon}" "${desc}" "${suffix}"
    else
        printf "\r\033[K  ✅ %s %s${_BAISH_COLOR_RESET}\n" "${icon}" "${desc}"
    fi
}

# Update a tool announcement on error — overwrites the "🔄" line.
# Args: tool_name, desc, error_message
baish_output_tool_announce_error() {
    local tool_name="$1"
    local desc="$2"
    local error_msg="$3"
    local icon
    icon=$(_baish_output_tool_icon "${tool_name}")
    printf "\r\033[K  ❌ %s %s — %s${_BAISH_COLOR_RESET}\n" "${icon}" "${desc}" "${error_msg}"
}

# Info and error messages
baish_output_error() {
    printf "${_BAISH_COLOR_RED}error: %s${_BAISH_COLOR_RESET}\n" "$1" >&2
}

baish_output_info() {
    printf "${_BAISH_COLOR_BLUE}%s${_BAISH_COLOR_RESET}\n" "$1"
}

# Thinking spinner (foreground and background)
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
}

# Background spinner: runs forever, printing to stderr so it doesn't pollute stdout.
# Should be launched as a background job: baish_output_thinking_bg &
# Note: When BAISH_USE_PIPELINE=1, the old spinner is disabled in favor of the pipeline.
baish_output_thinking_bg() {
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    # If pipeline is active, skip the old spinner
    if [[ -n "${BAISH_USE_PIPELINE:-}" && "${BAISH_USE_PIPELINE}" == "1" ]]; then
        return
    fi
    while true; do
        printf "\r${_BAISH_COLOR_CYAN}  %s thinking...${_BAISH_COLOR_RESET}" "${chars[$i]}" >&2
        i=$(( (i + 1) % ${#chars[@]} ))
        sleep 0.1
    done
}

# ── Staged Progress Pipeline ────────────────────────────────────────────────

# Pipeline state variables (global, modified by pipeline functions)
BAISH_PIPELINE_CURRENT_STAGE=""
BAISH_PIPELINE_RENDER_PID=""
BAISH_PIPELINE_TEMP_FILE=""
BAISH_PIPELINE_SKIP=0
BAISH_USE_PIPELINE=0

# Pipeline stage definitions (in display order)
_BAISH_PIPELINE_STAGES=("parse" "think" "execute" "done" "error")
_BAISH_PIPELINE_LABELS=("Parsing..." "Reasoning..." "Executing..." "Done" "Failed")
_BAISH_PIPELINE_EMOJIS=("🔍" "🧠" "⚙️" "✅" "❌")

# Get the 0-based index of a stage name. Returns -1 for invalid stages.
_baish_pipeline_stage_index() {
    local stage="$1"
    case "${stage}" in
        parse)   echo 0 ;;
        think)   echo 1 ;;
        execute) echo 2 ;;
        done)    echo 3 ;;
        error)   echo 4 ;;
        *)       echo -1 ;;
    esac
}

# Initialize the staged progress pipeline.
# Sets state variables. When BAISH_DEBUG=0 and stderr is a terminal,
# also starts a background renderer for the pulsing animation.
baish_output_pipeline_init() {
    BAISH_PIPELINE_CURRENT_STAGE=""
    BAISH_PIPELINE_RENDER_PID=""
    BAISH_PIPELINE_TEMP_FILE=""

    # Skip rendering in debug mode
    if [[ "${BAISH_DEBUG}" == "1" ]]; then
        BAISH_PIPELINE_SKIP=1
        BAISH_USE_PIPELINE=0
        return 0
    fi

    BAISH_PIPELINE_SKIP=0
    BAISH_USE_PIPELINE=1

    # Only start the background renderer if stderr is a terminal
    if [[ -t 2 ]]; then
        # Create temp file for stage communication with background renderer
        BAISH_PIPELINE_TEMP_FILE=$(mktemp /tmp/baish_pipeline.XXXXXX 2>/dev/null)
        if [[ -n "${BAISH_PIPELINE_TEMP_FILE}" && -f "${BAISH_PIPELINE_TEMP_FILE}" ]]; then
            echo "" > "${BAISH_PIPELINE_TEMP_FILE}"
            # Start background renderer
            _baish_output_pipeline_renderer &
            BAISH_PIPELINE_RENDER_PID=$!
        fi
    fi
}

# Advance the pipeline to a named stage.
# Valid stages: parse, think, execute, done, error
# Updates BAISH_PIPELINE_CURRENT_STAGE and renders the pipeline to stderr.
# NOTE: Must NOT be called inside a subshell ($(...)) to ensure the global
# state variable is updated. Call it directly, then capture output separately.
baish_output_pipeline_stage() {
    local stage="$1"

    # Validate stage name
    local idx
    idx=$(_baish_pipeline_stage_index "${stage}")
    if (( idx < 0 )); then
        baish_output_error "Invalid pipeline stage: ${stage}" >&2
        return 1
    fi

    BAISH_PIPELINE_CURRENT_STAGE="${stage}"

    # If skipping, just update state and return
    if [[ "${BAISH_PIPELINE_SKIP}" == "1" ]]; then
        return 0
    fi

    # Write stage to temp file for background renderer
    if [[ -n "${BAISH_PIPELINE_TEMP_FILE}" ]]; then
        printf '%s' "${stage}" > "${BAISH_PIPELINE_TEMP_FILE}"
    fi

    # Render the pipeline to stderr (immediate one-shot render)
    _baish_output_pipeline_render "${stage}" >&2

    # Terminal stages get a trailing newline so subsequent stderr output
    # (e.g. baish_output_error) doesn't concatenate onto the same line.
    # When the background renderer is active, its stray final render may
    # appear on the next line briefly but will be overwritten by the
    # "done" stage's \r\033[K prefix.
    if [[ "${stage}" == "done" || "${stage}" == "error" ]]; then
        printf '\n' >&2
    fi
}

# Render the pipeline line for a given stage.
# Shows only the active stage as a single badge, e.g., emoji + label.
# Active stage is bold+green. Terminal stages (done/error) show final state.
_baish_output_pipeline_render() {
    local current_stage="$1"
    local current_idx
    current_idx=$(_baish_pipeline_stage_index "${current_stage}")
    if (( current_idx < 0 )); then
        return 1
    fi
    local label="${_BAISH_PIPELINE_LABELS[$current_idx]}"
    local emoji="${_BAISH_PIPELINE_EMOJIS[$current_idx]}"
    printf "\r\033[K\033[1;32m%s %s\033[0m" "${emoji}" "${label}"
}

# Background pipeline renderer.
# Reads the current stage from the temp file in a loop and re-renders
# the pipeline with a pulsing effect on the active stage.
# The pulse alternates between bold+bright-green and bold+dim-green.
# Exits automatically on terminal stages (done/error).
_baish_output_pipeline_renderer() {
    local pulse=0

    while true; do
        local stage=""
        if [[ -f "${BAISH_PIPELINE_TEMP_FILE}" ]]; then
            stage=$(cat "${BAISH_PIPELINE_TEMP_FILE}" 2>/dev/null || echo "")
        fi

        if [[ -z "${stage}" ]]; then
            sleep 0.2
            continue
        fi

        local current_idx
        current_idx=$(_baish_pipeline_stage_index "${stage}")
        if (( current_idx < 0 )); then
            sleep 0.2
            continue
        fi

        local label="${_BAISH_PIPELINE_LABELS[$current_idx]}"
        local emoji="${_BAISH_PIPELINE_EMOJIS[$current_idx]}"
        local output
        # Active stage: pulse between bold+bright-green and bold+dim-green
        if (( pulse % 2 == 0 )); then
            output=$'\033[1;32m'"${emoji} ${label}"$'\033[0m'
        else
            output=$'\033[1;2m\033[32m'"${emoji} ${label}"$'\033[0m'
        fi
        printf "\r\033[K%s" "${output}"
        pulse=$(( (pulse + 1) % 4 ))
        sleep 0.3

        # If we've reached a terminal stage (done/error), render final and exit
        if [[ "${stage}" == "done" || "${stage}" == "error" ]]; then
            _baish_output_pipeline_render "${stage}"
            break
        fi
    done
}

# Clean up pipeline resources: kill background renderer, remove temp file.
baish_output_pipeline_cleanup() {
    if [[ -n "${BAISH_PIPELINE_RENDER_PID:-}" ]]; then
        kill "${BAISH_PIPELINE_RENDER_PID}" 2>/dev/null || true
        wait "${BAISH_PIPELINE_RENDER_PID}" 2>/dev/null || true
    fi
    if [[ -n "${BAISH_PIPELINE_TEMP_FILE:-}" && -f "${BAISH_PIPELINE_TEMP_FILE}" ]]; then
        rm -f "${BAISH_PIPELINE_TEMP_FILE}" 2>/dev/null || true
    fi
    BAISH_PIPELINE_RENDER_PID=""
    BAISH_PIPELINE_TEMP_FILE=""
    BAISH_PIPELINE_CURRENT_STAGE=""
    BAISH_USE_PIPELINE=0
    # Ensure a trailing newline after pipeline output so the next prompt starts on its own line
    printf "\n" >&2
}

# ============================================================================
# Error guidance messages
# ============================================================================

# Print user-facing guidance when context overflow is detected.
# ============================================================================
# Context summary — shown at startup
# ============================================================================

# Display a summary of additional context files loaded at startup:
# AGENTS.md files and any pre-loaded skills.
baish_output_context_summary() {
    local -a agents_files
    local i

    # Collect AGENTS.md loaded files
    while IFS= read -r f; do
        agents_files+=("${f}")
    done < <(baish_agents_md_get_loaded_files)

    local has_context=0

    # Show AGENTS.md files
    if [[ ${#agents_files[@]} -gt 0 ]]; then
        has_context=1
        local label="AGENTS.md"
        if [[ ${#agents_files[@]} -gt 1 ]]; then
            label="AGENTS.md files"
        fi
        printf "  ${_BAISH_COLOR_DIM}📋 Loaded ${label}:${_BAISH_COLOR_RESET}\n"
        for f in "${agents_files[@]}"; do
            # Show a relative path when possible
            local display_path="${f}"
            if [[ "${f}" == "${HOME}"/* ]]; then
                display_path="~/${f#${HOME}/}"
            fi
            printf "    ${_BAISH_COLOR_DIM}• %s${_BAISH_COLOR_RESET}\n" "${display_path}"
        done
    fi

    # Show loaded skills
    if [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -gt 0 ]]; then
        has_context=1
        local label="skill"
        if [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -gt 1 ]]; then
            label="skills"
        fi
        printf "  ${_BAISH_COLOR_DIM}🧠 Loaded ${label}:${_BAISH_COLOR_RESET}\n"
        for s in "${BAISH_SESSION_SKILL_NAMES[@]}"; do
            printf "    ${_BAISH_COLOR_DIM}• %s${_BAISH_COLOR_RESET}\n" "${s}"
        done
    fi

    if (( has_context == 0 )); then
        printf "  ${_BAISH_COLOR_DIM}📋 No additional context files loaded.${_BAISH_COLOR_RESET}\n"
    fi
    printf "\n"
}

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